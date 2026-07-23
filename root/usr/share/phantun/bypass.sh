#!/bin/sh
# phantun: force DNS-resolver traffic to leave via the physical WAN,
# bypassing any proxy (WireGuard/etc.) regardless of whether the proxy uses
# fwmark policy routing or replaces the main-table default route.
#
# Mechanism: a dedicated routing table (DNS_TABLE) holds a default route via
# the physical WAN gateway/device. A high-priority (low pref) ip rule matches
# packets destined to the resolver DNS IP and sends them to that table, so the
# lookup happens before any proxy rule can catch them.
#
# Why this matters for phantun: a client rule connects to the server by
# domain. If DNS resolution went through the tunnel, then whenever the tunnel
# drops the client can never re-resolve to reconnect -> permanent deadlock.
# Forcing DNS out the physical WAN breaks that cycle.
#
# This file is meant to be sourced by init.d and monitor.sh.

PH_DNS_TABLE=994
PH_DNS_PREF=101

# Return 0 if arg is an IPv6 literal (contains a colon)
_ph_is_v6() {
	case "$1" in *:*) return 0 ;; *) return 1 ;; esac
}

# Interface (logical name) to treat as the physical WAN. Empty => "wan".
# Set by callers (init.d / monitor.sh) from the wan_iface UCI option.
PH_WAN_IFACE=""

# Echo the effective WAN logical interface name.
ph_wan_iface() {
	if [ -n "$PH_WAN_IFACE" ]; then
		echo "$PH_WAN_IFACE"
	else
		echo "wan"
	fi
}

# Populate the dedicated table with a default route via the physical WAN.
_ph_refresh_wan_routes() {
	[ -f /lib/functions/network.sh ] || return 1
	. /lib/functions/network.sh
	network_flush_cache

	local gw dev gw6
	local ifc="$(ph_wan_iface)"

	# One physical WAN port -> same device for v4/v6; only gateways differ.
	network_get_device dev "$ifc"

	network_get_gateway gw "$ifc"
	if [ -n "$gw" ] || [ -n "$dev" ]; then
		ip route replace default ${gw:+via "$gw"} ${dev:+dev "$dev"} \
			table "$PH_DNS_TABLE" 2>/dev/null
	fi

	network_get_gateway6 gw6 "$ifc"
	if [ -n "$gw6" ] || [ -n "$dev" ]; then
		ip -6 route replace default ${gw6:+via "$gw6"} ${dev:+dev "$dev"} \
			table "$PH_DNS_TABLE" 2>/dev/null
	fi
	return 0
}

# Add a high-priority rule so packets to the given DNS IP use the WAN table.
ph_bypass_add() {
	local dns="$1"
	[ -n "$dns" ] || return 0

	_ph_refresh_wan_routes

	if _ph_is_v6 "$dns"; then
		ip -6 rule del to "$dns" table "$PH_DNS_TABLE" pref "$PH_DNS_PREF" 2>/dev/null
		ip -6 rule add to "$dns" table "$PH_DNS_TABLE" pref "$PH_DNS_PREF" 2>/dev/null
	else
		ip rule del to "$dns" table "$PH_DNS_TABLE" pref "$PH_DNS_PREF" 2>/dev/null
		ip rule add to "$dns" table "$PH_DNS_TABLE" pref "$PH_DNS_PREF" 2>/dev/null
	fi
}

# Remove the rule for a specific DNS IP.
ph_bypass_del() {
	local dns="$1"
	[ -n "$dns" ] || return 0

	if _ph_is_v6 "$dns"; then
		ip -6 rule del to "$dns" table "$PH_DNS_TABLE" pref "$PH_DNS_PREF" 2>/dev/null
	else
		ip rule del to "$dns" table "$PH_DNS_TABLE" pref "$PH_DNS_PREF" 2>/dev/null
	fi
}

# Flush everything (both the rule for this DNS and the whole table).
ph_bypass_flush() {
	local dns="$1"
	ph_bypass_del "$dns"
	ip route flush table "$PH_DNS_TABLE" 2>/dev/null
	ip -6 route flush table "$PH_DNS_TABLE" 2>/dev/null
}
