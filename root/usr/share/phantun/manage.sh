#!/bin/sh
# Phantun management helper: architecture detection, binary status,
# asynchronous initialization (download + extract), version tracking,
# update checking, and a rolling init log the web UI streams in real time.
#
# Also provides per-rule diagnostics for the web UI: live handshake status
# (from conntrack), the currently-resolved peer IP for domain-based client
# rules, and a filtered error/event log (noise like per-connection churn
# stripped out, so the UI shows only lines that actually indicate a problem).
#
# Download strategy (all via curl):
#   1. Concurrent HEAD race across mirrors -> pick the fastest responder.
#   2. Download from the winner using a STALL timeout (never a total timeout),
#      so slow-but-progressing downloads are not killed at 90%.
#   3. On download failure, fall back to the next mirror automatically.
#
# Usage:
#   manage.sh status | init | update [tag] | init_status
#   manage.sh cur_version | cur_repo | check_update | log
#   manage.sh rule_conn <name> | rule_resolved <name> | rule_log <name>
#   manage.sh switch_repo <owner/repo> [tag]

. /lib/functions.sh

BIN_DIR=/usr/bin
SERVER_BIN="$BIN_DIR/phantun_server"
CLIENT_BIN="$BIN_DIR/phantun_client"
STATE_FILE=/tmp/phantun_init.status
LOG_FILE=/tmp/phantun_init.log
LOG_MAX=100
TMP_DIR=/tmp/phantun_dl
VERSION_FILE=/usr/share/phantun/.version
REPO_FILE=/usr/share/phantun/.repo
RUN_STATE_DIR=/var/run/phantun

# Default source repo is this project's own fork (adds the opt-in --time TCP
# fingerprint flag on top of upstream, see fake-tcp changes), not the
# upstream dndx/phantun. Both are plain "owner/repo" GitHub paths; switching
# is fully supported (see cmd_switch_repo) since the download/update logic
# below never hardcodes which repo it talks to.
DEFAULT_REPO="Dage1819/phantun"
PHANTUN_REPO="$DEFAULT_REPO"
if command -v uci >/dev/null 2>&1; then
	_r=$(uci -q get phantun.global.repo 2>/dev/null)
	[ -n "$_r" ] && PHANTUN_REPO="$_r"
fi

# No release tag is hardcoded here. Every initialization, update check, and
# repository switch resolves the newest published release from that repository
# at runtime. This is important because repositories may use different tag
# schemes (for example v0.8.1 versus v0.8.1-fp1) and may publish prereleases.

# Accepts either a bare "owner/repo" or a full GitHub URL in any of these
# forms and normalizes to "owner/repo":
#   owner/repo
#   github.com/owner/repo
#   https://github.com/owner/repo
#   https://github.com/owner/repo/releases
#   https://github.com/owner/repo/releases/tag/vX.Y.Z
#   https://github.com/owner/repo.git
normalize_repo() {
	local in="$1"
	in="${in#https://}"
	in="${in#http://}"
	in="${in#github.com/}"
	in="${in%.git}"
	# Keep only the first two path segments (owner/repo), drop anything
	# after (e.g. /releases, /releases/tag/vX, /tree/main, trailing slash).
	echo "$in" | cut -d'/' -f1-2
}

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

# The repo the currently-installed binaries actually came from (may differ
# from $PHANTUN_REPO if the uci setting was changed but switch_repo has not
# been run yet -- the UI uses this, not the uci value, to detect that case).
# Falls back to the configured/default repo when nothing has been installed
# yet, so a first-time "check update" before init still checks the right place.
cmd_cur_repo() {
	if [ -f "$REPO_FILE" ]; then cat "$REPO_FILE"
	else echo "$PHANTUN_REPO"; fi
}

# Concurrent race across mirrors + direct GitHub for the release-info JSON,
# same "first valid responder wins" strategy as race_mirrors() below uses
# for downloads. Sequentially trying each mirror (the old behavior) could
# take 20-28s per dead mirror before falling through, which is what made
# "check update" occasionally look like it had failed when it had really
# just not gotten to a working mirror yet. Echoes the winning response body,
# or nothing if every mirror failed within the wait window.
race_check_update_body() {
	local apiurl="$1"
	local racedir="$TMP_DIR/check_race"
	rm -rf "$racedir"; mkdir -p "$racedir"
	local winner="$racedir/winner"
	local idx=0

	for m in $MIRRORS ""; do
		idx=$((idx + 1))
		(
			local b
			b=$(curl -fsL --connect-timeout 8 -m 15 "${m}${apiurl}" 2>/dev/null)
			if [ -n "$b" ] && echo "$b" | grep -q '"tag_name"'; then
				# Atomic-ish claim: first writer wins.
				[ -f "$winner" ] || { echo "$b" > "$racedir/body_$idx" && echo "$idx" > "$winner"; }
			fi
		) &
	done

	local waited=0
	while [ ! -f "$winner" ] && [ "$waited" -lt 16 ]; do
		sleep 1; waited=$((waited + 1))
	done
	wait 2>/dev/null

	if [ -f "$winner" ]; then
		cat "$racedir/body_$(cat "$winner")" 2>/dev/null
		rm -rf "$racedir"
		return 0
	fi
	rm -rf "$racedir"
	return 1
}

# Query the repository release list and return its newest release tag.
# The GitHub API returns releases in publication order. This deliberately
# includes prereleases because a fork may publish its usable build as one.
# The repository itself decides the tag spelling; no tag is hardcoded here.
get_latest_version() {
	local repo="$1" body latest
	local apiurl="https://api.github.com/repos/${repo}/releases"
	body=$(race_check_update_body "$apiurl")
	[ -n "$body" ] || return 1
	latest=$(echo "$body" | grep -o '"tag_name"[ ]*:[ ]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[ ]*:[ ]*"//;s/"//')
	[ -n "$latest" ] || return 1
	echo "$latest"
}

# Query GitHub for the latest release tag of $1 (owner/repo, defaults to the
# configured repo); print "latest|<tag>|<newer>". All releases, including
# prereleases, are considered because a fork may intentionally publish its
# usable build as a prerelease.
cmd_check_update() {
	local repo="${1:-$PHANTUN_REPO}"
	local latest cur
	latest=$(get_latest_version "$repo") || { echo "error"; return 1; }
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

# Different repos (e.g. a third-party fork with its own release naming
# convention) may not name assets exactly "phantun_<target>.zip" the way
# this project and upstream dndx/phantun both happen to. Rather than assume
# a fixed filename pattern, ask GitHub's release-by-tag API for the actual
# asset list and pick whichever asset name *contains* our target triple
# (e.g. "aarch64-unknown-linux-musl"), regardless of prefix/suffix/extension
# conventions. Prints the resolved browser_download_url, or nothing if the
# API lookup failed or no asset matched (caller falls back to the hardcoded
# pattern in that case, preserving old behavior for repos where this lookup
# can't run, e.g. no network yet for the API call specifically).
resolve_asset_url() {
	local repo="$1" ver="$2" target="$3"
	local apiurl="https://api.github.com/repos/${repo}/releases/tags/${ver}"
	local body; body=$(race_check_update_body "$apiurl")
	[ -n "$body" ] || return 1

	# OpenWrt normally ships jsonfilter; use it so release.name and asset.name
	# cannot get mixed up by a naive grep over the whole JSON document.
	if command -v jsonfilter >/dev/null 2>&1; then
		local names urls i n u
		names=$(printf '%s' "$body" | jsonfilter -e '@.assets[*].name' 2>/dev/null)
		urls=$(printf '%s' "$body" | jsonfilter -e '@.assets[*].browser_download_url' 2>/dev/null)
		i=0
		while IFS= read -r n; do
			i=$((i + 1))
			case "$n" in
				*"$target"*.zip|*"$target"*.ZIP)
					u=$(printf '%s\n' "$urls" | sed -n "${i}p")
					[ -n "$u" ] && { echo "$u"; return 0; }
					;;
			esac
		done <<-EOF
$names
EOF
		return 1
	fi

	# Minimal fallback for systems without jsonfilter: restrict parsing to
	# asset objects, then match the target in the asset name and obtain the
	# URL from the same object. Known phantun releases use the conventional
	# name and are still handled by the download URL fallback below.
	local asset
	asset=$(printf '%s' "$body" | tr '{' '\n' | grep 'browser_download_url' | grep '"name"[ ]*:[ ]*"[^"]*'"$target"'"' | head -1)
	[ -n "$asset" ] || return 1
	echo "$asset" | grep -o '"browser_download_url"[ ]*:[ ]*"[^"]*"' | sed 's/.*"browser_download_url"[ ]*:[ ]*"//;s/"$//' | head -1
}

do_download() {
	local ver="$1"
	local repo="${2:-$PHANTUN_REPO}"
	local target ghpath total winner url
	# The caller must resolve a real release tag before entering download.
	# Do not fall back to any compile-time/default version here.
	[ -n "$ver" ] || { log "错误：未解析到发布版本"; set_state "error:no_version"; return 1; }

	log "开始初始化 Phantun $ver（仓库：$repo）"
	log "检测系统架构：$(uname -m)"
	target=$(detect_target)
	if [ -z "$target" ]; then
		log "错误：不支持的架构 $(uname -m)"
		set_state "error:unsupported_arch:$(uname -m)"; return 1
	fi
	log "匹配目标平台：$target"

	set_state "downloading"
	rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"

	# If the asset API cannot be queried, fail closed instead of guessing a
	# filename. Different repositories may use arbitrary asset names, and a
	# guessed URL could install the wrong archive or an HTML error page.
	local resolved zipname
	resolved=$(resolve_asset_url "$repo" "$ver" "$target")
	if [ -z "$resolved" ]; then
		log "错误：发布中没有匹配 $target 的 ZIP 资源，或资源列表查询失败"
		set_state "error:asset_not_found"
		rm -rf "$TMP_DIR"
		return 1
	fi
	ghpath="$resolved"
	zipname=$(basename "${resolved%%\?*}")
	[ -n "$zipname" ] || zipname="phantun-${target}.zip"
	log "已从发布资源列表匹配到文件：$zipname"
	local zip="$TMP_DIR/$zipname"

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
		echo "$repo" > "$REPO_FILE"
		log "安装完成，Phantun $ver 已就绪（仓库：$repo）"
		set_state "ready"
	else
		log "错误：安装后未检测到可执行文件（磁盘空间不足？）"
		log "可用空间：$(df -h "$BIN_DIR" 2>/dev/null | tail -1)"
		set_state "error:install_failed"; return 1
	fi
}

# $1=version tag (optional explicit override) $2=owner/repo (defaults to configured repo)
start_async() {
	local ver="$1"
	local repo="${2:-$PHANTUN_REPO}"
	[ -n "$ver" ] || { echo "error:no_release"; return 1; }
	if [ -f "$STATE_FILE" ]; then
		local cur; cur=$(cat "$STATE_FILE")
		case "$cur" in
			downloading|extracting|installing_unzip) echo "$cur"; return 0 ;;
		esac
	fi
	log_reset
	set_state "downloading"
	( do_download "$ver" "$repo" ) >/dev/null 2>&1 &
	echo "started"
}

cmd_init() {
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then
		set_state "ready"; echo "ready"; return 0
	fi
	# First initialization always resolves the newest release of the selected
	# repository. There is deliberately no hardcoded version fallback.
	local ver
	ver=$(get_latest_version "$PHANTUN_REPO")
	[ -n "$ver" ] || { echo "error:no_release"; return 1; }
	start_async "$ver" "$PHANTUN_REPO"
}

cmd_update() {
	local ver="$1"
	if [ -z "$ver" ]; then
		ver=$(get_latest_version "$PHANTUN_REPO")
	fi
	[ -n "$ver" ] || { echo "error:no_release"; return 1; }
	start_async "$ver" "$PHANTUN_REPO"
}

# Switch to a different source repo and immediately re-initialize: downloads
# the given (or latest, if omitted) release from the new repo and replaces
# the installed binaries. $1=owner/repo or full GitHub URL (normalized via
# normalize_repo), $2=optional version tag (defaults to that repo's latest
# release). Does NOT touch uci -- the web UI is responsible for persisting
# the new repo setting only after this call succeeds, so an aborted/failed
# switch never leaves the saved config pointing at a repo whose binaries
# were not actually installed.
cmd_switch_repo() {
	local repo; repo=$(normalize_repo "$1")
	[ -n "$repo" ] && [ "$repo" != "/" ] || { echo "error:bad_repo"; return 1; }
	# A repository switch without an explicit tag always resolves the newest
	# release from the *new repository*, including prereleases. Tag spelling is
	# never inferred or copied from the old repository.
	local ver="$2"
	[ -n "$ver" ] || ver=$(get_latest_version "$repo")
	[ -n "$ver" ] || { echo "error:no_release"; return 1; }
	start_async "$ver" "$repo"
}

# ---- Per-rule diagnostics for the web UI ----
#
# Look up the uci rule section whose "name" option matches $1 (falling back
# to treating $1 as the section id itself), and echo "mode|local_port|remote_port".
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

# Handshake/connection status for one rule, derived from live conntrack
# state rather than log parsing, so it reflects the current moment rather
# than something that may have happened minutes ago.
# Output: one of established | handshaking | none
cmd_rule_conn() {
	local name="$1"
	[ -n "$name" ] || { echo "none"; return 0; }
	local info; info=$(_rule_lookup "$name")
	[ -n "$info" ] || { echo "none"; return 0; }
	local mode lp rp
	mode=$(echo "$info" | cut -d'|' -f2)
	lp=$(echo "$info" | cut -d'|' -f3)
	rp=$(echo "$info" | cut -d'|' -f4)

	# Server listens on local_port; client connects out to remote_port. Either
	# way the TCP port of interest shows up as "dport=<port>" on the original
	# (request) direction of the conntrack entry.
	local port
	if [ "$mode" = "server" ]; then port="$lp"; else port="$rp"; fi
	[ -n "$port" ] || { echo "none"; return 0; }

	local lines
	lines=$(grep "dport=${port} " /proc/net/nf_conntrack 2>/dev/null)
	[ -n "$lines" ] || { echo "none"; return 0; }

	# Check SYN_SENT/SYN_RECV FIRST, not ESTABLISHED. Phantun's fake-tcp uses
	# a fresh source port on every retry, so a stale ESTABLISHED entry from a
	# connection that worked hours ago (conntrack's default TCP ESTABLISHED
	# timeout is ~5 days) can sit in the table at the same time as brand-new
	# SYN_SENT entries from the current, actively-failing retry loop. Simply
	# grepping for "ESTABLISHED" anywhere in the table falsely reports success
	# while the tunnel is actually stuck retrying right now. An active
	# handshake attempt in progress is always the more current, trustworthy
	# signal, so it takes priority over any ESTABLISHED line.
	if echo "$lines" | grep -qE "SYN_SENT|SYN_RECV"; then
		echo "handshaking"
	elif echo "$lines" | grep -q "ESTABLISHED"; then
		echo "established"
	else
		echo "none"
	fi
}

# Currently-resolved peer IP for a domain-based client rule (written by
# init.d's start_rule each time it resolves). Empty output if the rule's
# remote is a literal IP (nothing to resolve) or has never started.
cmd_rule_resolved() {
	local name="$1"
	[ -n "$name" ] || { echo ""; return 0; }
	local info; info=$(_rule_lookup "$name")
	local cfg; cfg=$(echo "$info" | cut -d'|' -f1)
	[ -n "$cfg" ] && [ -f "$RUN_STATE_DIR/$cfg.resolved" ] && cat "$RUN_STATE_DIR/$cfg.resolved" || echo ""
}

# Filtered, most-recent log lines for one rule: only lines that indicate an
# actual event (error, timeout, connection closed, startup info) -- the
# per-attempt noise ("Sent SYN to server", "New UDP client from ...", which
# repeat every retry/reconnect) is stripped so the modal only shows what
# matters. Caveat: procd/syslog tags phantun's own stdout by binary name
# (phantun_client / phantun_server), not by rule name, so if you run more
# than one rule of the same mode their logs are not distinguishable here --
# this is a logging limitation of phantun itself, not something the UI can
# work around without changing how phantun logs.
cmd_rule_log() {
	local name="$1"
	[ -n "$name" ] || { echo ""; return 0; }
	local info; info=$(_rule_lookup "$name")
	[ -n "$info" ] || { echo ""; return 0; }
	local mode; mode=$(echo "$info" | cut -d'|' -f2)
	local tag; [ "$mode" = "server" ] && tag="phantun_server" || tag="phantun_client"

	local keep='ERROR|timed out|Unable to connect|cannot resolve|closed|Created TUN|Remote address is|listening|denied|refused|panic'
	logread -e "$tag" 2>/dev/null | grep -E "$keep" | tail -100
}

case "$1" in
	status)        cmd_status ;;
	init)          cmd_init ;;
	update)        cmd_update "$2" ;;
	init_status)   cmd_init_status ;;
	cur_version)   cmd_cur_version ;;
	cur_repo)      cmd_cur_repo ;;
	check_update)  cmd_check_update "$2" ;;
	log)           cmd_log ;;
	rule_conn)     cmd_rule_conn "$2" ;;
	rule_resolved) cmd_rule_resolved "$2" ;;
	rule_log)      cmd_rule_log "$2" ;;
	switch_repo)   cmd_switch_repo "$2" "$3" ;;
	*)             echo "usage: $0 {status|init|update|init_status|cur_version|cur_repo|check_update|log|rule_conn|rule_resolved|rule_log|switch_repo}" >&2; exit 1 ;;
esac
