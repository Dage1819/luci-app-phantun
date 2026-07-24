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
# Fix: for client rules that opt in (route_via_wan='1'), install a dedicated
# routing table holding a default route via the PHYSICAL WAN, plus a high-
# priority ip rule steering packets destined to the server IP into that table.
# Only that single destination bypasses the tunnel; everything else still goes
# through it.
#
# Because the server address may be a domain whose IP changes over time, the
# actual resolved IP(s) we install are recorded per-rule in a state file so we
# can remove *exactly* those on stop / disable / IP-change / uninstall, even if
# a later resolution returns a different address.
#
# Sourced by init.d and monitor.sh. IPv4 and IPv6 are handled separately (v4 ->
# /32 + v4 WAN gateway; v6 -> /128 + v6 WAN gateway).

PH_ROUTE_TABLE=995
PH_ROUTE_PREF=102
PH_ROUTE_STATE_DIR=/var/run/phantun

# Physical WAN logical interface (set by callers from wan_iface UCI option).
# Empty => "wan".
PH_ROUTE_WAN_IFACE=""

_ph_r_is_v6() {
	case "$1" in *:*) return 0 ;; *) return 1 ;; esac
}

_ph_route_wan_iface() {
	if [ -n "$PH_ROUTE_WAN_IFACE" ]; then echo "$PH_ROUTE_WAN_IFACE"
	elif [ -n "$PH_WAN_IFACE" ]; then echo "$PH_WAN_IFACE"
	else echo "wan"; fi
}

# (Re)populate the dedicated table with a default route via the physical WAN,
# for both address families. Safe to call repeatedly (uses "route replace").
_ph_route_refresh_wan() {
	[ -f /lib/functions/network.sh ] || return 1
	. /lib/functions/network.sh
	network_flush_cache

	local gw dev gw6
	local ifc="$(_ph_route_wan_iface)"

	network_get_device dev "$ifc"

	network_get_gateway gw "$ifc"
	if [ -n "$gw" ] || [ -n "$dev" ]; then
		ip route replace default ${gw:+via "$gw"} ${dev:+dev "$dev"} \
			table "$PH_ROUTE_TABLE" 2>/dev/null
	fi

	network_get_gateway6 gw6 "$ifc"
	if [ -n "$gw6" ] || [ -n "$dev" ]; then
		ip -6 route replace default ${gw6:+via "$gw6"} ${dev:+dev "$dev"} \
			table "$PH_ROUTE_TABLE" 2>/dev/null
	fi
	return 0
}

# Add an exception rule for one server IP, recording it under the rule's cfg
# so it can be removed precisely later.
# $1=ip  $2=cfg (uci section name)
ph_route_add() {
	local ip="$1" cfg="$2"
	[ -n "$ip" ] || return 0

	mkdir -p "$PH_ROUTE_STATE_DIR" 2>/dev/null
	_ph_route_refresh_wan

	if _ph_r_is_v6 "$ip"; then
		ip -6 rule del to "$ip" table "$PH_ROUTE_TABLE" pref "$PH_ROUTE_PREF" 2>/dev/null
		ip -6 rule add to "$ip" table "$PH_ROUTE_TABLE" pref "$PH_ROUTE_PREF" 2>/dev/null
	else
		ip rule del to "$ip" table "$PH_ROUTE_TABLE" pref "$PH_ROUTE_PREF" 2>/dev/null
		ip rule add to "$ip" table "$PH_ROUTE_TABLE" pref "$PH_ROUTE_PREF" 2>/dev/null
	fi

	# Record (dedup) the IP under this rule for precise teardown.
	if [ -n "$cfg" ]; then
		local f="$PH_ROUTE_STATE_DIR/$cfg.route"
		grep -qxF "$ip" "$f" 2>/dev/null || echo "$ip" >> "$f"
	fi
	logger -t phantun "route: server exception $ip -> physical WAN (table $PH_ROUTE_TABLE)"
}

# Remove one IP's exception rule (does not touch the state file).
_ph_route_del_ip() {
	local ip="$1"
	[ -n "$ip" ] || return 0
	if _ph_r_is_v6 "$ip"; then
		ip -6 rule del to "$ip" table "$PH_ROUTE_TABLE" pref "$PH_ROUTE_PREF" 2>/dev/null
	else
		ip rule del to "$ip" table "$PH_ROUTE_TABLE" pref "$PH_ROUTE_PREF" 2>/dev/null
	fi
}

# Remove all exception rules recorded for one rule (cfg) and drop its state.
# $1=cfg
ph_route_del_cfg() {
	local cfg="$1"
	[ -n "$cfg" ] || return 0
	local f="$PH_ROUTE_STATE_DIR/$cfg.route"
	[ -f "$f" ] || return 0
	local ip
	while read -r ip; do
		[ -n "$ip" ] && _ph_route_del_ip "$ip"
	done < "$f"
	rm -f "$f"
}

# Nuke every exception rule/state we ever created (stop-all / uninstall).
ph_route_flush_all() {
	# Delete all ip rules at our pref (loop until none remain), both families.
	while ip rule del pref "$PH_ROUTE_PREF" 2>/dev/null; do :; done
	while ip -6 rule del pref "$PH_ROUTE_PREF" 2>/dev/null; do :; done
	ip route flush table "$PH_ROUTE_TABLE" 2>/dev/null
	ip -6 route flush table "$PH_ROUTE_TABLE" 2>/dev/null
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
