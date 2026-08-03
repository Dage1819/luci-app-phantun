#!/bin/sh
# Phantun management helper: architecture detection, binary status,
# initialization (download + extract), version tracking, update checking,
# and a rolling init log the web UI streams in real time.
#
# Also provides per-rule diagnostics for the web UI: live handshake status
# (from conntrack), the currently-resolved peer IP for domain-based client
# rules, and a filtered error/event log.
#
# Download strategy:
#   1. Try ghproxy.net mirror first (fastest for CN).
#   2. Fall back to direct GitHub on failure.
#   Version is resolved by scraping the /releases/latest HTML page
#   (no GitHub API needed -- api.github.com is blocked by most mirrors).
#
# Manual install (SSH):
#   Copy binaries directly to /usr/bin/phantun_client and
#   /usr/bin/phantun_server, chmod +x, then restart the service.
#   Version will show as "unknown" since no .version file is written.
#
# Usage:
#   manage.sh status | init_status | cur_version | cur_repo | log
#   manage.sh init | check_update
#   manage.sh rule_conn <name> | rule_resolved <name> | rule_log <name>

. /lib/functions.sh

BIN_DIR=/usr/bin
SERVER_BIN="$BIN_DIR/phantun_server"
CLIENT_BIN="$BIN_DIR/phantun_client"
STATE_FILE=/tmp/phantun_init.status
LOG_FILE=/tmp/phantun_init.log
LOG_MAX=100
TMP_DIR=/tmp/phantun_dl
VERSION_FILE=/usr/share/phantun/.version
RUN_STATE_DIR=/var/run/phantun

DEFAULT_REPO="Dage1819/phantun"
PHANTUN_REPO="$DEFAULT_REPO"
if command -v uci >/dev/null 2>&1; then
	_r=$(uci -q get phantun.global.repo 2>/dev/null)
	case "$_r" in
		[!/]*/*) PHANTUN_REPO="$(echo "$_r" | cut -d/ -f1-2)" ;;
	esac
fi

# Two download nodes: ghproxy.net mirror (no API proxy, but proxies download
# URLs), and direct GitHub as fallback.
MIRROR_PROXY="https://ghproxy.net/"
MIRROR_DIRECT=""   # empty = direct github.com

log() {
	local ts; ts=$(date '+%H:%M:%S')
	echo "[$ts] $1" >> "$LOG_FILE"
	local n; n=$(wc -l < "$LOG_FILE" 2>/dev/null)
	[ "${n:-0}" -gt "$LOG_MAX" ] && tail -n "$LOG_MAX" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}
log_reset() { : > "$LOG_FILE"; }
set_state() { echo "$1" > "$STATE_FILE"; }

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

# Scrape the latest release tag from the releases/latest HTML page.
# No GitHub API needed -- uses ghproxy.net first, then direct.
# Outputs the tag (e.g. v0.8.1-fp1) or empty on failure.
get_latest_tag() {
	local repo="$1" tag url html
	# Try proxy first, then direct
	for prefix in "$MIRROR_PROXY" "$MIRROR_DIRECT"; do
		url="${prefix}https://github.com/${repo}/releases/latest"
		html=$(curl -fsSL --connect-timeout 10 -m 20 "$url" 2>/dev/null)
		tag=$(echo "$html" | grep -o 'tag/[^"]*' | head -1 | sed 's|tag/||')
		[ -n "$tag" ] && echo "$tag" && return 0
	done
	return 1
}

cmd_status() {
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then echo "ready"; else echo "missing"; fi
}

cmd_init_status() {
	if [ -f "$STATE_FILE" ]; then
		local cur; cur=$(cat "$STATE_FILE")
		case "$cur" in
			downloading|extracting) echo "$cur"; return 0 ;;
		esac
	fi
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then echo "ready"
	else echo "missing"; fi
}

cmd_log() { [ -f "$LOG_FILE" ] && cat "$LOG_FILE" || echo ""; }

cmd_cur_version() {
	if [ -f "$VERSION_FILE" ]; then cat "$VERSION_FILE"
	elif [ -x "$CLIENT_BIN" ]; then echo "unknown"
	else echo "none"; fi
}

cmd_cur_repo() { echo "$PHANTUN_REPO"; }

# Download a URL to a file, trying proxy first then direct.
# $1=ghpath (e.g. https://github.com/owner/repo/releases/download/...)
# $2=output file
download_file() {
	local ghurl="$1" out="$2" url
	for prefix in "$MIRROR_PROXY" "$MIRROR_DIRECT"; do
		url="${prefix}${ghurl}"
		log "尝试下载：$url"
		if curl -fL --connect-timeout 12 --speed-time 30 --speed-limit 2048 \
			-o "$out" "$url" >/dev/null 2>&1 && [ -s "$out" ]; then
			return 0
		fi
		log "下载失败，尝试下一节点"
	done
	return 1
}

do_download() {
	local repo="$1"
	log_reset
	set_state "downloading"

	log "检测系统架构：$(uname -m)"
	local target; target=$(detect_target)
	[ -n "$target" ] || { log "错误：不支持的架构 $(uname -m)"; set_state "error:unsupported_arch"; return 1; }
	log "目标平台：$target"

	log "查询最新版本…"
	local ver; ver=$(get_latest_tag "$repo")
	[ -n "$ver" ] || { log "错误：无法获取最新版本（请检查网络）"; set_state "error:no_version"; return 1; }
	log "最新版本：$ver"

	rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
	local zip="$TMP_DIR/phantun.zip"
	local ghurl="https://github.com/${repo}/releases/download/${ver}/phantun_${target}.zip"

	set_state "downloading"
	download_file "$ghurl" "$zip" || {
		log "错误：所有节点下载失败"
		set_state "error:download_failed"
		rm -rf "$TMP_DIR"
		return 1
	}
	log "下载完成（$(wc -c < "$zip") 字节）"

	set_state "extracting"
	log "正在解压…"
	if ! unzip -o "$zip" -d "$TMP_DIR" >/dev/null 2>&1; then
		log "错误：解压失败"
		set_state "error:extract_failed"
		rm -rf "$TMP_DIR"
		return 1
	fi

	local client_bin server_bin
	client_bin=$(find "$TMP_DIR" -name "phantun_client" -type f | head -1)
	server_bin=$(find "$TMP_DIR" -name "phantun_server" -type f | head -1)
	[ -n "$client_bin" ] && [ -n "$server_bin" ] || {
		log "错误：压缩包内未找到 phantun_client / phantun_server"
		set_state "error:binary_not_found"
		rm -rf "$TMP_DIR"
		return 1
	}

	cp "$client_bin" "$CLIENT_BIN" && chmod 0755 "$CLIENT_BIN" || {
		log "错误：安装 phantun_client 失败"
		set_state "error:install_failed"
		rm -rf "$TMP_DIR"
		return 1
	}
	cp "$server_bin" "$SERVER_BIN" && chmod 0755 "$SERVER_BIN" || {
		log "错误：安装 phantun_server 失败"
		set_state "error:install_failed"
		rm -rf "$TMP_DIR"
		return 1
	}

	echo "$ver" > "$VERSION_FILE"
	rm -rf "$TMP_DIR"
	log "安装完成：$ver"
	set_state "ready"
}

cmd_init() {
	# If already running, don't start another
	if [ -f "$STATE_FILE" ]; then
		local cur; cur=$(cat "$STATE_FILE")
		case "$cur" in
			downloading|extracting) echo "started"; return 0 ;;
		esac
	fi
	log_reset
	set_state "downloading"
	( do_download "$PHANTUN_REPO" ) >/dev/null 2>&1 &
	echo "started"
}

cmd_check_update() {
	local cur_ver latest
	cur_ver=$(cmd_cur_version)
	latest=$(get_latest_tag "$PHANTUN_REPO")
	[ -n "$latest" ] || { echo "error:fetch_failed"; return 1; }
	if [ "$cur_ver" = "$latest" ]; then
		echo "latest|$latest|0"
	else
		echo "latest|$latest|1"
	fi
}

# Look up a UCI rule by its displayed name.
_rule_lookup() {
	local want="$1"
	local found="" fmode="" flp="" frp=""
	_match() {
		local cfg="$1" nm mode lp rp
		[ -z "$found" ] || return 0
		config_get nm "$cfg" name "$cfg"
		[ "$nm" = "$want" ] || return 0
		config_get mode "$cfg" mode "client"
		config_get lp "$cfg" local_port ""
		config_get rp "$cfg" remote_port ""
		found="$cfg"; fmode="$mode"; flp="$lp"; frp="$rp"
	}
	config_load phantun
	config_foreach _match rule
	[ -n "$found" ] && echo "${found}|${fmode}|${flp}|${frp}"
}

cmd_rule_conn() {
	local name="$1" info mode lp rp port lines
	[ -n "$name" ] || { echo "none"; return 0; }
	info=$(_rule_lookup "$name")
	[ -n "$info" ] || { echo "none"; return 0; }
	mode=$(echo "$info" | cut -d'|' -f2)
	lp=$(echo "$info" | cut -d'|' -f3)
	rp=$(echo "$info" | cut -d'|' -f4)
	if [ "$mode" = "server" ]; then port="$lp"; else port="$rp"; fi
	[ -n "$port" ] || { echo "none"; return 0; }
	lines=$(grep "dport=${port} " /proc/net/nf_conntrack 2>/dev/null)
	[ -n "$lines" ] || { echo "none"; return 0; }
	if echo "$lines" | grep -qE "SYN_SENT|SYN_RECV"; then
		echo "handshaking"
	elif echo "$lines" | grep -q "ESTABLISHED"; then
		echo "established"
	else
		echo "none"
	fi
}

cmd_rule_resolved() {
	local name="$1" info cfg
	[ -n "$name" ] || { echo ""; return 0; }
	info=$(_rule_lookup "$name")
	cfg=$(echo "$info" | cut -d'|' -f1)
	[ -n "$cfg" ] && [ -f "$RUN_STATE_DIR/$cfg.resolved" ] && cat "$RUN_STATE_DIR/$cfg.resolved" || echo ""
}

cmd_rule_log() {
	local name="$1" info mode tag
	[ -n "$name" ] || { echo ""; return 0; }
	info=$(_rule_lookup "$name")
	[ -n "$info" ] || { echo ""; return 0; }
	mode=$(echo "$info" | cut -d'|' -f2)
	[ "$mode" = "server" ] && tag="phantun_server" || tag="phantun_client"
	logread -e "$tag" 2>/dev/null | grep -E 'ERROR|timed out|Unable to connect|cannot resolve|closed|Created TUN|Remote address is|listening|denied|refused|panic' | tail -100
}

case "$1" in
	status)        cmd_status ;;
	init_status)   cmd_init_status ;;
	init)          cmd_init ;;
	log)           cmd_log ;;
	cur_version)   cmd_cur_version ;;
	cur_repo)      cmd_cur_repo ;;
	check_update)  cmd_check_update ;;
	rule_conn)     cmd_rule_conn "$2" ;;
	rule_resolved) cmd_rule_resolved "$2" ;;
	rule_log)      cmd_rule_log "$2" ;;
	*) echo "usage: $0 {status|init_status|init|log|cur_version|cur_repo|check_update|rule_conn|rule_resolved|rule_log}" >&2; exit 1 ;;
esac
