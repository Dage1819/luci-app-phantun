#!/bin/sh
# Phantun management helper for manual core uploads and per-rule diagnostics.
# The router never calls GitHub APIs, downloads release archives, or extracts
# ZIP files. LuCI uploads the two ELF binaries to fixed temporary paths and
# this helper installs them under their canonical names.
#
# Usage:
#   manage.sh status | init_status | upload_info
#   manage.sh install_binary <client|server> </tmp/fixed-upload-path>
#   manage.sh rule_conn <name> | rule_resolved <name> | rule_log <name>

. /lib/functions.sh

BIN_DIR=/usr/bin
SERVER_BIN="$BIN_DIR/phantun_server"
CLIENT_BIN="$BIN_DIR/phantun_client"
RUN_STATE_DIR=/var/run/phantun
DEFAULT_REPO="Dage1819/phantun"
PHANTUN_REPO="$DEFAULT_REPO"

if command -v uci >/dev/null 2>&1; then
	_r=$(uci -q get phantun.global.repo 2>/dev/null)
	case "$_r" in
		[!/]*/*) PHANTUN_REPO="$(echo "$_r" | cut -d/ -f1-2)" ;;
	esac
fi

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

cmd_status() {
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then echo "ready"; else echo "missing"; fi
}

cmd_init_status() {
	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then
		echo "ready"
	elif [ -x "$SERVER_BIN" ]; then
		echo "missing:client"
	elif [ -x "$CLIENT_BIN" ]; then
		echo "missing:server"
	else
		echo "missing"
	fi
}

cmd_upload_info() {
	local target
	target=$(detect_target)
	[ -n "$target" ] || { echo "error:unsupported_arch:$(uname -m)"; return 1; }
	echo "${target}|phantun_${target}.zip|https://github.com/${PHANTUN_REPO}/releases"
}

# Install one binary uploaded by LuCI. The browser-side filename is irrelevant;
# role and a fixed upload path select the canonical destination.
cmd_install_binary() {
	local role="$1" src="$2" expected dst magic service_was_running=0
	case "$role" in
		client)
			expected="/tmp/phantun_upload_client"
			dst="$CLIENT_BIN"
			;;
		server)
			expected="/tmp/phantun_upload_server"
			dst="$SERVER_BIN"
			;;
		*) echo "error:bad_role"; return 1 ;;
	esac

	[ "$src" = "$expected" ] || { echo "error:bad_path"; return 1; }
	[ -f "$src" ] && [ -s "$src" ] || { rm -f "$src"; echo "error:empty_file"; return 1; }

	# Reject ZIP files, text, and downloaded error pages. Do not execute the
	# untrusted upload for validation; startup will reveal any arch mismatch.
	magic=$(hexdump -n 4 -e '4/1 "%02x"' "$src" 2>/dev/null)
	[ "$magic" = "7f454c46" ] || { rm -f "$src"; echo "error:not_elf"; return 1; }

	pgrep -x phantun_client >/dev/null 2>&1 && service_was_running=1
	pgrep -x phantun_server >/dev/null 2>&1 && service_was_running=1
	[ "$service_was_running" = "1" ] && /etc/init.d/phantun stop >/dev/null 2>&1

	if ! cp "$src" "${dst}.new" 2>/dev/null || ! chmod 0755 "${dst}.new" 2>/dev/null || ! mv -f "${dst}.new" "$dst" 2>/dev/null; then
		rm -f "$src" "${dst}.new"
		[ "$service_was_running" = "1" ] && /etc/init.d/phantun start >/dev/null 2>&1
		echo "error:install_failed"
		return 1
	fi
	rm -f "$src"
	[ "$service_was_running" = "1" ] && /etc/init.d/phantun start >/dev/null 2>&1

	if [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ]; then echo "ready"; else echo "installed:$role"; fi
}

# Look up a UCI rule by its displayed name and echo:
# section|mode|local_port|remote_port
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
	status)          cmd_status ;;
	init_status)     cmd_init_status ;;
	upload_info)     cmd_upload_info ;;
	install_binary)  cmd_install_binary "$2" "$3" ;;
	rule_conn)       cmd_rule_conn "$2" ;;
	rule_resolved)   cmd_rule_resolved "$2" ;;
	rule_log)        cmd_rule_log "$2" ;;
	*) echo "usage: $0 {status|init_status|upload_info|install_binary|rule_conn|rule_resolved|rule_log}" >&2; exit 1 ;;
esac