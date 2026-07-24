#!/bin/sh
# phantun: "server exception route" helper.
#
# Problem this solves: when the box's default route is pointed entirely into a
# tunnel (e.g. a WireGuard full-tunnel / global proxy), packets destined to the
# Phantun *server* also get routed into that tunnel. But the tunnel can only
# come up once Phantun is connected -> a self-dependency deadlock: the SYN that
# Phantun sends to the server disappears into a not-yet-established tunnel and
# no SYN+ACK ever comes back.
#
# Fix: for client rules that opt in (route_via_wan='1'), add a host route for
# the Phantun server IP via the PHYSICAL WAN interface. Because it is a /32
# (or /128) host route, it is more specific than the tunnel's default route
# and wins the lookup in the SAME table -- no dedicated table/ip-rule needed
# as long as the tunnel's default route lives in the main table (the common
# case for a WireGuard full-tunnel).
#
# These routes are written as regular UCI "config route" / "config route6"
# sections in /etc/config/network, tagged with a "phantun_<rule>_v4"/"_v6"
# name and a comment identifying the source rule. This makes them show up in
# LuCI's own "Network -> Static Routes" page (IPv4 and IPv6 tabs, matching
# OpenWrt's own separation of the two families) so they are visible and
# editable through the normal UI, not just via the command line.
#
# Because the server address may be a domain whose IP changes over time, the
# actual resolved IP(s) we install are recorded per-rule in a state file so we
# can remove *exactly* those on stop / disable / IP-change / uninstall, even if
# a later resolution returns a different address.
#
# Sourced by init.d and monitor.sh. IPv4 and IPv6 are handled through separate
# UCI section types (route / route6), matching how OpenWrt itself keeps them
# on separate tabs -- never mixed into one section.

PH_ROUTE_STATE_DIR=/var/run/phantun

# Physical WAN logical interface (set by callers from wan_iface UCI option).
# Empty => "wan". This is a *logical* interface name (as used by netifd and
# by LuCI's own static-route "interface" field), not a device name.
PH_ROUTE_WAN_IFACE=""

_ph_r_is_v6() {
	case "$1" in *:*) return 0 ;; *) return 1 ;; esac
}

_ph_route_wan_iface() {
	if [ -n "$PH_ROUTE_WAN_IFACE" ]; then echo "$PH_ROUTE_WAN_IFACE"
	elif [ -n "$PH_WAN_IFACE" ]; then echo "$PH_WAN_IFACE"
	else echo "wan"; fi
}

# Extract the "via <gw>" of the kernel's own default route on a given device.
# Used as a fallback when netifd's network_get_gateway(6) comes back empty,
# which happens with link-local (fe80::) IPv6 gateways and/or source-specific
# ("from <prefix> via ... dev ...") default routes -- both common on real ISP
# IPv6 delegations. Parsing the kernel's actual route table is the most
# reliable source of truth in those cases.
# $1=family flag for ip ("" for v4, "-6" for v6)  $2=dev
_ph_route_kernel_gw() {
	local fam="$1" dev="$2"
	[ -n "$dev" ] || return 0
	ip $fam route list default dev "$dev" 2>/dev/null | \
		awk '{ for (i=1;i<=NF;i++) if ($i=="via") { print $(i+1); exit } }' | head -1
}

# Resolve the physical WAN's device name + v4/v6 gateways. Sets the globals
# _PH_DEV / _PH_GW / _PH_GW6 (empty string if a gateway is genuinely on-link
# or could not be determined).
_ph_route_wan_info() {
	local ifc="$(_ph_route_wan_iface)"
	_PH_DEV=""; _PH_GW=""; _PH_GW6=""

	if [ -f /lib/functions/network.sh ]; then
		. /lib/functions/network.sh
		network_flush_cache
		network_get_device _PH_DEV "$ifc"
		network_get_gateway _PH_GW "$ifc" 2>/dev/null
		network_get_gateway6 _PH_GW6 "$ifc" 2>/dev/null
	fi
	# Fall back to the logical name as the device name if netifd lookup failed.
	[ -n "$_PH_DEV" ] || _PH_DEV="$ifc"

	# netifd came back empty -> ask the kernel's actual routing table instead.
	[ -n "$_PH_GW" ]  || _PH_GW=$(_ph_route_kernel_gw ""   "$_PH_DEV")
	[ -n "$_PH_GW6" ] || _PH_GW6=$(_ph_route_kernel_gw "-6" "$_PH_DEV")
}

# Add (or replace) the server-exception route for one rule. Writes a named UCI
# route/route6 section (visible on LuCI's Static Routes page) AND applies it
# to the kernel immediately, so it takes effect without a full "network"
# reload (which could be disruptive, e.g. re-dialing PPPoE).
# $1=ip  $2=cfg (uci section id)  $3=display name (optional, for the comment)
ph_route_add() {
	local ip="$1" cfg="$2" name="$3"
	[ -n "$ip" ] && [ -n "$cfg" ] || return 0
	mkdir -p "$PH_ROUTE_STATE_DIR" 2>/dev/null

	local ifc="$(_ph_route_wan_iface)"
	_ph_route_wan_info

	if _ph_r_is_v6 "$ip"; then
		local sec="phantun_${cfg}_v6"
		uci -q delete network."$sec" 2>/dev/null
		uci set network."$sec"="route6"
		uci set network."$sec".interface="$ifc"
		uci set network."$sec".target="${ip}/128"
		[ -n "$_PH_GW6" ] && uci set network."$sec".gateway="$_PH_GW6"
		uci set network."$sec".comment="phantun: ${name:-$cfg} (server exception route)"
		uci commit network

		ip -6 route replace "${ip}/128" ${_PH_GW6:+via "$_PH_GW6"} dev "$_PH_DEV" 2>/dev/null
	else
		local sec="phantun_${cfg}_v4"
		uci -q delete network."$sec" 2>/dev/null
		uci set network."$sec"="route"
		uci set network."$sec".interface="$ifc"
		uci set network."$sec".target="$ip"
		uci set network."$sec".netmask="255.255.255.255"
		[ -n "$_PH_GW" ] && uci set network."$sec".gateway="$_PH_GW"
		uci set network."$sec".comment="phantun: ${name:-$cfg} (server exception route)"
		uci commit network

		ip route replace "${ip}/32" ${_PH_GW:+via "$_PH_GW"} dev "$_PH_DEV" 2>/dev/null
	fi

	# Record (dedup) the IP under this rule for precise teardown.
	local f="$PH_ROUTE_STATE_DIR/$cfg.route"
	grep -qxF "$ip" "$f" 2>/dev/null || echo "$ip" >> "$f"
	logger -t phantun "route: server exception $ip -> physical WAN ($ifc) via static route $sec"
}

# Remove both possible UCI sections (v4/v6) + their kernel routes for one
# rule, and drop its state file. Safe to call even if nothing was ever added.
# $1=cfg
ph_route_del_cfg() {
	local cfg="$1"
	[ -n "$cfg" ] || return 0
	local changed=0 tgt

	if uci -q get network."phantun_${cfg}_v4" >/dev/null 2>&1; then
		tgt=$(uci -q get network."phantun_${cfg}_v4".target)
		uci -q delete network."phantun_${cfg}_v4"
		[ -n "$tgt" ] && ip route del "${tgt}/32" 2>/dev/null
		changed=1
	fi
	if uci -q get network."phantun_${cfg}_v6" >/dev/null 2>&1; then
		tgt=$(uci -q get network."phantun_${cfg}_v6".target)
		uci -q delete network."phantun_${cfg}_v6"
		[ -n "$tgt" ] && ip -6 route del "$tgt" 2>/dev/null
		changed=1
	fi
	[ "$changed" = "1" ] && uci commit network

	rm -f "$PH_ROUTE_STATE_DIR/$cfg.route"
}

# Nuke every exception route/state we ever created, for every rule (stop-all
# / uninstall). Finds sections purely by our "phantun_*" naming convention so
# it also cleans up entries left behind by a renamed/removed rule.
ph_route_flush_all() {
	local changed=0 sec tgt

	for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\(phantun_[^.]*\)=route$/\1/p'); do
		tgt=$(uci -q get network."$sec".target)
		uci -q delete network."$sec"
		[ -n "$tgt" ] && ip route del "${tgt}/32" 2>/dev/null
		changed=1
	done
	for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\(phantun_[^.]*\)=route6$/\1/p'); do
		tgt=$(uci -q get network."$sec".target)
		uci -q delete network."$sec"
		[ -n "$tgt" ] && ip -6 route del "$tgt" 2>/dev/null
		changed=1
	done
	[ "$changed" = "1" ] && uci commit network

	rm -f "$PH_ROUTE_STATE_DIR"/*.route 2>/dev/null
	return 0
}

# CLI entry so postrm/other scripts can flush without sourcing. Guarded by
# $0: when this file is sourced (". route.sh" from init.d/monitor.sh), $0 is
# the CALLER's path (e.g. /etc/rc.common), not route.sh, so this block is
# skipped entirely. Only a DIRECT invocation ("route.sh flush_all") hits it.
# Without this guard, sourcing would run this case against init.d's own $1
# (start/stop/rule_stop/...), fall into the `*` branch, and `exit 1` would
# kill the whole sourcing init.d process.
case "$0" in
	*/route.sh|route.sh)
		case "$1" in
			flush_all) ph_route_flush_all ;;
			"") : ;;
			*) echo "usage: $0 {flush_all}" >&2; exit 1 ;;
		esac
		;;
esac
