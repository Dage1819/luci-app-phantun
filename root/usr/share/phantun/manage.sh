#!/bin/sh
# Phantun management helper: architecture detection, binary status,
# asynchronous initialization (download + extract), version tracking,
# update checking, and a rolling init log the web UI streams in real time.
#
# Download strategy (all via curl):
#   1. Concurrent HEAD race across mirrors -> pick the fastest responder.
#   2. Download from the winner using a STALL timeout (never a total timeout),
#      so slow-but-progressing downloads are not killed at 90%.
#   3. On download failure, fall back to the next mirror automatically.
#
# Usage:
#   manage.sh status | init | update [tag] | init_status
#   manage.sh cur_version | check_update | log

BIN_DIR=/usr/bin
SERVER_BIN="$BIN_DIR/phantun_server"
CLIENT_BIN="$BIN_DIR/phantun_client"
STATE_FILE=/tmp/phantun_init.status
LOG_FILE=/tmp/phantun_init.log
LOG_MAX=100
TMP_DIR=/tmp/phantun_dl
VERSION_FILE=/usr/share/phantun/.version

PHANTUN_VERSION="v0.8.1"
if command -v uci >/dev/null 2>&1; then
	_v=$(uci -q get phantun.global.version 2>/dev/null)
	[ -n "$_v" ] && PHANTUN_VERSION="$_v"
fi

# Acceleration mirrors. Each is prepended to the full "https://github.com/..."
# URL. The last (empty) entry means a direct GitHub connection as a fallback.
# gh.ddlc.top / ghfast.top are verified working; direct GitHub last.
MIRRORS="
https://gh.ddlc.top/
https://ghfast.top/
https://ghproxy.net/
https://github.moeyy.xyz/
"

log() {
	local ts; ts=$(date '+%H:%M:%S')
	echo "[$ts] $1" >> "$LOG_FILE"
	if [ -f "$LOG_FILE" ]; then
		local n; n=$(wc -l < "$LOG_FILE" 2>/dev/null)
		if [ "${n:-0}" -gt "$LOG_MAX" ]; then
			tail -n "$LOG_MAX" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
		fi
	fi
}
log_reset() { : > "$LOG_FILE"; }

detect_target() {
	local m; m=$(uname -m)
	case "$m" in
		aarch64|arm64)      echo "aarch64-unknown-linux-musl" ;;
		armv7l|armv7)       echo "armv7-unknown-linux-musleabihf" ;;
		armv6l|armv5*|arm)  echo "arm-unknown-linux-musleabihf" ;;
		x86_64|amd64)       echo "x86_64-unknown-linux-musl" ;;
		i686|i386|x86)      echo "i686-unknown-linux-musl" ;;
		mips)               echo "mips-unknown-linux-musl_nightly" ;;
		mipsel)             echo "mipsel-unknown-linux-musl_nightly" ;;
		mips64)             echo "mips64-unknown-linux-muslabi64_nightly" ;;
		*)                  echo "" ;;
	esac
}

set_state() { echo "$1" > "$STATE_FILE"; }

cmd_status() {
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then echo "ready"; else echo "missing"; fi
}

cmd_init_status() {
	if [ -f "$STATE_FILE" ]; then
		local cur; cur=$(cat "$STATE_FILE")
		case "$cur" in
			downloading|extracting|installing_unzip) echo "$cur"; return 0 ;;
		esac
	fi
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then echo "ready"; return 0; fi
	if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo "missing"; fi
}

cmd_log() { [ -f "$LOG_FILE" ] && cat "$LOG_FILE" || echo ""; }

cmd_cur_version() {
	if [ -f "$VERSION_FILE" ]; then cat "$VERSION_FILE"
	elif [ -x "$CLIENT_BIN" ]; then echo "unknown"
	else echo "none"; fi
}

# Query GitHub for the latest release tag; print "latest|<tag>|<newer>".
cmd_check_update() {
	local body latest cur m
	local apiurl="https://api.github.com/repos/dndx/phantun/releases/latest"
	body=""
	for m in $MIRRORS ""; do
		body=$(curl -fsL --connect-timeout 8 -m 20 "${m}${apiurl}" 2>/dev/null)
		[ -n "$body" ] && break
	done
	if [ -z "$body" ]; then
		latest=$(curl -fsL --connect-timeout 8 -m 20 "https://github.com/dndx/phantun/releases/latest" 2>/dev/null | grep -o 'tag/v[0-9.]*' | head -1 | sed 's,tag/,,')
	else
		latest=$(echo "$body" | grep -o '"tag_name"[ ]*:[ ]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[ ]*:[ ]*"//;s/"//')
	fi
	[ -z "$latest" ] && { echo "error"; return 1; }
	cur=$(cmd_cur_version)
	if [ "$latest" != "$cur" ]; then echo "latest|$latest|1"; else echo "latest|$latest|0"; fi
}

# Concurrent HEAD race: probe every mirror's response header in parallel,
# the first mirror to return a valid HTTP status wins. Echoes the winning
# mirror prefix (may be empty for direct), or nothing on total failure.
race_mirrors() {
	local ghpath="$1"
	local racedir="$TMP_DIR/race"
	rm -rf "$racedir"; mkdir -p "$racedir"
	local winner="$racedir/winner"
	local idx=0

	for m in $MIRRORS ""; do
		idx=$((idx + 1))
		(
			# -I header only, short timeouts. Success = HTTP 200/302 seen.
			if curl -sI --connect-timeout 6 -m 12 "${m}${ghpath}" 2>/dev/null | grep -qE '^HTTP/.* (200|302|301)'; then
				# Atomic-ish claim: first writer wins.
				[ -f "$winner" ] || echo "$m" > "$winner"
			fi
		) &
	done

	# Wait up to ~13s for a winner to appear.
	local waited=0
	while [ ! -f "$winner" ] && [ "$waited" -lt 13 ]; do
		sleep 1; waited=$((waited + 1))
	done
	wait 2>/dev/null

	if [ -f "$winner" ]; then
		cat "$winner"
		return 0
	fi
	return 1
}

# Download $1(url) -> $2(file) with a STALL timeout (no total timeout), and
# report progress into the log using the known total size $3 (bytes, optional).
download_with_progress() {
	local url="$1" out="$2" total="$3"

	# Start curl in the background so we can watch the growing file size.
	# --speed-time/--speed-limit: abort only if <2KB/s for 30s (true stall),
	# never a hard total timeout, so slow downloads finish.
	curl -fL --connect-timeout 12 --speed-time 30 --speed-limit 2048 \
		-o "$out" "$url" >/dev/null 2>&1 &
	local pid=$!

	local last=0 shown=0
	while kill -0 "$pid" 2>/dev/null; do
		sleep 2
		if [ -f "$out" ]; then
			local cur; cur=$(wc -c < "$out" 2>/dev/null); cur=${cur:-0}
			if [ "$cur" != "$last" ]; then
				last="$cur"
				if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
					local pct=$(( cur * 100 / total ))
					log "下载中… ${pct}%  ($((cur/1024))KB / $((total/1024))KB)"
				else
					log "下载中… $((cur/1024))KB"
				fi
				shown=1
			fi
		fi
	done

	wait "$pid"
	return $?
}

do_download() {
	local ver="$1"
	local target ghpath total winner url
	[ -n "$ver" ] || ver="$PHANTUN_VERSION"

	log "开始初始化 Phantun $ver"
	log "检测系统架构：$(uname -m)"
	target=$(detect_target)
	if [ -z "$target" ]; then
		log "错误：不支持的架构 $(uname -m)"
		set_state "error:unsupported_arch:$(uname -m)"; return 1
	fi
	log "匹配目标平台：$target"

	set_state "downloading"
	rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
	local zip="$TMP_DIR/phantun_${target}.zip"
	ghpath="https://github.com/dndx/phantun/releases/download/${ver}/phantun_${target}.zip"

	# 1) Concurrent header race to pick the fastest mirror.
	log "正在并发测速，选择最佳节点…"
	winner=$(race_mirrors "$ghpath")
	if [ $? -ne 0 ]; then
		log "测速失败：所有节点均无响应，将按顺序逐个尝试下载"
		winner="__ordered__"
	fi

	# Build the ordered list of mirrors to try: winner first, then the rest.
	local trylist=""
	if [ "$winner" = "__ordered__" ]; then
		trylist="$MIRRORS "
	else
		trylist="$winner"
		local m
		for m in $MIRRORS ""; do
			[ "$m" = "$winner" ] && continue
			trylist="$trylist $m"
		done
		[ -n "$winner" ] && log "最佳节点：${winner}"
		[ -z "$winner" ] && log "最佳节点：直连 GitHub"
	fi

	# Fetch total size (best effort) for progress percentage.
	total=$(curl -sI --connect-timeout 6 -m 12 "${winner}${ghpath}" 2>/dev/null | grep -i '^content-length:' | tr -d '\r' | awk '{print $2}' | tail -1)
	[ -n "$total" ] && log "文件大小：$((total/1024))KB"

	# 2) Try mirrors in order until one download succeeds.
	local ok=0 m
	for m in $trylist; do
		[ "$m" = "__none__" ] && m=""
		url="${m}${ghpath}"
		if [ -z "$m" ]; then log "尝试下载（直连 GitHub）：$url"
		else log "尝试下载：$url"; fi
		if download_with_progress "$url" "$zip" "$total" && [ -s "$zip" ]; then
			ok=1
			log "下载完成（$(( $(wc -c < "$zip") / 1024 ))KB）"
			break
		fi
		log "该节点下载失败，尝试下一个…"
	done
	if [ "$ok" != "1" ]; then
		log "错误：所有节点下载均失败，请检查网络"
		set_state "error:download_failed"; rm -rf "$TMP_DIR"; return 1
	fi

	# 3) Ensure unzip, then extract.
	if ! command -v unzip >/dev/null 2>&1; then
		log "未找到 unzip，尝试自动安装…"
		set_state "installing_unzip"
		opkg update >/dev/null 2>&1
		opkg install unzip >/dev/null 2>&1
	fi
	if ! command -v unzip >/dev/null 2>&1; then
		log "错误：unzip 不可用且自动安装失败"
		set_state "error:no_unzip"; rm -rf "$TMP_DIR"; return 1
	fi

	set_state "extracting"
	log "正在解压…"
	if ! unzip -o "$zip" -d "$TMP_DIR" >/dev/null 2>&1; then
		log "错误：解压失败"
		set_state "error:extract_failed"; rm -rf "$TMP_DIR"; return 1
	fi

	log "解压出的文件：$(find "$TMP_DIR" -type f -name 'phantun_*' 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
	local s c
	s=$(find "$TMP_DIR" -type f -name 'phantun_server' 2>/dev/null | head -1)
	c=$(find "$TMP_DIR" -type f -name 'phantun_client' 2>/dev/null | head -1)
	if [ -z "$s" ] || [ -z "$c" ]; then
		log "错误：压缩包内未找到 phantun_server / phantun_client"
		set_state "error:binary_not_found"; rm -rf "$TMP_DIR"; return 1
	fi

	log "安装到 $BIN_DIR …"
	install -m 0755 "$s" "$SERVER_BIN" 2>/dev/null || cp "$s" "$SERVER_BIN" 2>/dev/null
	install -m 0755 "$c" "$CLIENT_BIN" 2>/dev/null || cp "$c" "$CLIENT_BIN" 2>/dev/null
	chmod 0755 "$SERVER_BIN" "$CLIENT_BIN" 2>/dev/null
	rm -rf "$TMP_DIR"

	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then
		mkdir -p "$(dirname "$VERSION_FILE")" 2>/dev/null
		echo "$ver" > "$VERSION_FILE"
		log "安装完成，Phantun $ver 已就绪"
		set_state "ready"
	else
		log "错误：安装后未检测到可执行文件（磁盘空间不足？）"
		log "可用空间：$(df -h "$BIN_DIR" 2>/dev/null | tail -1)"
		set_state "error:install_failed"; return 1
	fi
}

start_async() {
	local ver="$1"
	if [ -f "$STATE_FILE" ]; then
		local cur; cur=$(cat "$STATE_FILE")
		case "$cur" in
			downloading|extracting|installing_unzip) echo "$cur"; return 0 ;;
		esac
	fi
	log_reset
	set_state "downloading"
	( do_download "$ver" ) >/dev/null 2>&1 &
	echo "started"
}

cmd_init() {
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then
		set_state "ready"; echo "ready"; return 0
	fi
	start_async "$PHANTUN_VERSION"
}

cmd_update() {
	local ver="$1"
	if [ -z "$ver" ]; then
		local r; r=$(cmd_check_update)
		ver=$(echo "$r" | cut -d'|' -f2)
	fi
	[ -n "$ver" ] || { echo "error:no_version"; return 1; }
	start_async "$ver"
}

case "$1" in
	status)       cmd_status ;;
	init)         cmd_init ;;
	update)       cmd_update "$2" ;;
	init_status)  cmd_init_status ;;
	cur_version)  cmd_cur_version ;;
	check_update) cmd_check_update ;;
	log)          cmd_log ;;
	*)            echo "usage: $0 {status|init|update|init_status|cur_version|check_update|log}" >&2; exit 1 ;;
esac
