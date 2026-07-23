#!/bin/sh
# Phantun firewall helper (UCI-based, reload/reboot safe).
#
# Only SERVER rules need firewall automation: the public TCP port must be
# DNAT'd to phantun_server's TUN address, and the traffic accepted. Because
# phantun_server reads packets FROM the TUN interface (192.168.201.2 / fcc9::2)
# rather than binding a socket, a plain "open port" is not enough.
#
# CLIENT rules need nothing: the local app (e.g. WireGuard) points at the
# local phantun UDP port (127.0.0.1), which is host output/input traffic and
# never traverses the forward chain; egress SNAT is already covered by fw4's
# default WAN masquerade.
#
# We write real UCI firewall entries (config redirect + config rule) tagged
# with a per-rule id, so they survive fw4 reloads and reboots. Only server
# rules with auto_fw='1' get entries; everything else is cleaned up.
#
# Phantun server TUN defaults (v0.8.x):
#   IPv4 192.168.201.2   IPv6 fcc9::2

. /lib/functions.sh

SERVER_V4="192.168.201.2"
SERVER_V6="fcc9::2"

# Tag used to identify our auto-generated firewall entries in UCI.
TAG_PREFIX="phantun_"

# Remove all firewall entries we previously created (any section whose
# name option starts with our tag). Safe to call repeatedly.
fw_clear_all() {
	local changed=0
	# redirects (DNAT)
	while :; do
		local sid
		sid=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@redirect\[[0-9]*\]\)\.name='${TAG_PREFIX}.*/\1/p" | head -1)
		[ -n "$sid" ] || break
		uci -q delete "firewall.${sid}" || break
		changed=1
	done
	# rules (accept)
	while :; do
		local sid
		sid=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@rule\[[0-9]*\]\)\.name='${TAG_PREFIX}.*/\1/p" | head -1)
		[ -n "$sid" ] || break
		uci -q delete "firewall.${sid}" || break
		changed=1
	done
	if [ "$changed" = "1" ]; then
		uci -q commit firewall
		CLEARED=1
	fi
	return 0
}

# Add firewall entries for one server rule.
# $1=rule name  $2=tcp port  $3=family (ipv4|ipv6|both)
#
# fw4 redirect/rule sections accept a "family" option; DNAT dest_ip must match
# that family. For "both" we create one entry per family so v4 and v6 inbound
# TCP are each forwarded to the matching TUN address.
fw_add_one() {
	local tag="$1" port="$2" fam="$3" dest="$4"

	# DNAT: WAN inbound tcp/<port> -> server TUN address for this family.
	local r
	r=$(uci add firewall redirect)
	uci -q set "firewall.$r.name=${tag}"
	uci -q set "firewall.$r.target=DNAT"
	uci -q set "firewall.$r.src=wan"
	uci -q set "firewall.$r.proto=tcp"
	uci -q set "firewall.$r.family=${fam}"
	uci -q set "firewall.$r.src_dport=${port}"
	uci -q set "firewall.$r.dest_ip=${dest}"
	uci -q set "firewall.$r.dest_port=${port}"

	# Accept the forwarded traffic to the TUN dest (fw4 forward default drop).
	local a
	a=$(uci add firewall rule)
	uci -q set "firewall.$a.name=${tag}"
	uci -q set "firewall.$a.src=wan"
	uci -q set "firewall.$a.proto=tcp"
	uci -q set "firewall.$a.family=${fam}"
	uci -q set "firewall.$a.dest_port=${port}"
	uci -q set "firewall.$a.dest_ip=${dest}"
	uci -q set "firewall.$a.target=ACCEPT"

	logger -t phantun "firewall: DNAT+accept ${fam} tcp/${port} -> ${dest} (${tag})"
}

# $1=rule name  $2=tcp port  $3=family (ipv4|ipv6|both, default ipv4)
fw_add_server() {
	local name="$1" port="$2" family="$3"
	local tag="${TAG_PREFIX}${name}"
	[ -n "$family" ] || family="ipv4"

	case "$family" in
		ipv6)
			fw_add_one "$tag" "$port" "ipv6" "$SERVER_V6"
			;;
		both|any)
			fw_add_one "$tag" "$port" "ipv4" "$SERVER_V4"
			fw_add_one "$tag" "$port" "ipv6" "$SERVER_V6"
			;;
		*)
			fw_add_one "$tag" "$port" "ipv4" "$SERVER_V4"
			;;
	esac
}

# Iterate server rules; collect those with auto_fw enabled.
# Server rules always get BOTH IPv4 and IPv6 port-forwards (v4 -> 192.168.201.2,
# v6 -> fcc9::2), so the user does not have to choose an address family: the
# server just listens on a TCP port and accepts whoever connects.
_want=""
collect_server() {
	local cfg="$1"
	local enabled mode local_port auto_fw name
	config_get_bool enabled "$cfg" enabled 0
	[ "$enabled" = "1" ] || return 0
	config_get mode "$cfg" mode "client"
	[ "$mode" = "server" ] || return 0
	# Default to enabled (1) when the field is absent: LuCI does not persist a
	# Flag whose value equals its default, and the UI default is checked (1).
	# So a server rule the user never touched has no auto_fw key but should
	# still get firewall automation. Only an explicit '0' disables it.
	config_get_bool auto_fw "$cfg" auto_fw 1
	[ "$auto_fw" = "1" ] || return 0
	config_get local_port "$cfg" local_port ""
	[ -n "$local_port" ] || return 0
	config_get name "$cfg" name "$cfg"
	_want="${_want} ${name}|${local_port}"
}

apply() {
	# Always start from a clean slate so unchecked/removed rules are cleared.
	# fw_clear_all returns non-empty (via CLEARED) if it removed anything.
	CLEARED=0
	fw_clear_all
	local cleared="$CLEARED"

	config_load phantun
	_want=""
	config_foreach collect_server rule

	local any=0 entry
	for entry in $_want; do
		# entry = name|port  (server always gets both v4 + v6 forwards)
		local name="${entry%%|*}"
		local port="${entry##*|}"
		fw_add_server "$name" "$port" "both"
		any=1
	done

	# Reload if we added new entries OR if we cleared stale ones (so that
	# unchecking the last auto_fw rule actually takes effect immediately).
	if [ "$any" = "1" ]; then
		uci -q commit firewall
		/etc/init.d/firewall reload >/dev/null 2>&1
		logger -t phantun "firewall: committed + reloaded"
	elif [ "$cleared" = "1" ]; then
		/etc/init.d/firewall reload >/dev/null 2>&1
		logger -t phantun "firewall: cleared stale entries + reloaded"
	fi
	return 0
}

# On stop/uninstall: remove all our entries and reload.
flush() {
	fw_clear_all
	/etc/init.d/firewall reload >/dev/null 2>&1
	return 0
}

case "$1" in
	apply) apply ;;
	flush) flush ;;
	*)     echo "usage: $0 {apply|flush}" >&2; exit 1 ;;
esac
