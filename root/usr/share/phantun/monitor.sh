#!/bin/sh
# Phantun DDNS monitor.
#
# Phantun resolves the --remote domain only once at startup. For client rules
# whose remote is a domain, this watcher periodically re-resolves it and
# restarts the phantun service when the resolved IP changes, so the tunnel
# follows a moving peer address (dynamic DNS).
#
# Only enabled client rules with a domain remote_addr and monitor='1' are
# watched. Resolution mirrors udp2raw-ultra: a primary resolver (host) with a
# fallback (drill), and if the configured DNS yields nothing it retries with
# the system default resolver.

. /lib/functions.sh

BYPASS=/usr/share/phantun/bypass.sh
[ -f "$BYPASS" ] && . "$BYPASS"
ROUTE_HELPER=/usr/share/phantun/route.sh
[ -f "$ROUTE_HELPER" ] && . "$ROUTE_HELPER"

STATE_DIR=/var/run/phantun
mkdir -p "$STATE_DIR"

CHECK_INTERVAL="60"
DNS_SERVER=""
BYPASS_PROXY="1"

is_ip_literal() {
	local addr="$1"
	case "$addr" in
		*[!0-9.]*) ;;
		*.*.*.*) return 0 ;;
	esac
	case "$addr" in
		*:*) return 0 ;;
	esac
	return 1
}

# Resolve a domain according to family (ipv4 -> A, ipv6 -> AAAA). Tries the
# configured DNS first, then falls back to the system default resolver.
resolve_addr() {
	local domain="$1" family="$2" dns="$3"
	local ip=""

	_host_a()    { host -t A    "$domain" $1 2>/dev/null | awk '/has address/ {print $NF; exit}'; }
	_host_aaaa() { host -t AAAA "$domain" $1 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}'; }

	_drill_a() {
		local s=""; [ -n "$1" ] && s="@$1"
		drill "$domain" $s A 2>/dev/null | awk '!/^;/ && $4=="A" {print $5; exit}'
	}
	_drill_aaaa() {
		local s=""; [ -n "$1" ] && s="@$1"
		drill "$domain" $s AAAA 2>/dev/null | awk '!/^;/ && $4=="AAAA" {print $5; exit}'
	}

	_resolve_a() {
		if command -v host >/dev/null 2>&1; then _host_a "$1"; else _drill_a "$1"; fi
	}
	_resolve_aaaa() {
		if command -v host >/dev/null 2>&1; then _host_aaaa "$1"; else _drill_aaaa "$1"; fi
	}

	_try() {
		local d="$1"
		case "$family" in
			ipv6) _resolve_aaaa "$d" ;;
			*)    _resolve_a "$d" ;;
		esac
	}

	ip=$(_try "$dns")
	if [ -z "$ip" ] && [ -n "$dns" ]; then
		ip=$(_try "")
	fi
	echo "$ip"
}

MONITORED=""

collect_rule() {
	local cfg="$1"
	local enabled mode remote_addr family monitor route_via_wan name

	config_get_bool enabled "$cfg" enabled 0
	[ "$enabled" = "1" ] || return 0
	config_get mode "$cfg" mode "client"
	[ "$mode" = "client" ] || return 0
	# Watch a rule if the user asked for DDNS monitoring, OR if it uses the
	# server-exception route: a domain peer whose IP changes would otherwise
	# leave a stale /32 (/128) route pointing at the old server IP, breaking
	# the tunnel until the next manual restart. Either flag pulls it in.
	config_get_bool monitor "$cfg" monitor 0
	config_get_bool route_via_wan "$cfg" route_via_wan 0
	[ "$monitor" = "1" ] || [ "$route_via_wan" = "1" ] || return 0
	config_get remote_addr "$cfg" remote_addr ""
	[ -n "$remote_addr" ] || return 0
	is_ip_literal "$remote_addr" && return 0

	config_get family "$cfg" family "ipv4"
	config_get name "$cfg" name "$cfg"
	MONITORED="$MONITORED $cfg|$remote_addr|$family|$name"
}

config_load phantun
config_get DNS_SERVER global dns_server ""
config_get CHECK_INTERVAL global check_interval "60"
config_get_bool BYPASS_PROXY global bypass_proxy 1
config_get PH_WAN_IFACE global wan_iface ""
config_foreach collect_rule rule

# Nothing to watch -> cheap idle loop (procd keeps us alive).
if [ -z "$MONITORED" ]; then
	while true; do sleep 3600; done
fi

# Seed current IPs.
for entry in $MONITORED; do
	cfg=$(echo "$entry" | cut -d'|' -f1)
	dom=$(echo "$entry" | cut -d'|' -f2)
	fam=$(echo "$entry" | cut -d'|' -f3)
	ip=$(resolve_addr "$dom" "$fam" "$DNS_SERVER")
	[ -n "$ip" ] && echo "$ip" > "$STATE_DIR/$cfg.ip"
done

while true; do
	sleep "$CHECK_INTERVAL"

	# Keep the DNS-bypass WAN route fresh: a PPPoE re-dial can change the
	# gateway, which would otherwise leave the bypass table pointing at a
	# stale route.
	if [ "$BYPASS_PROXY" = "1" ] && [ -n "$DNS_SERVER" ] && command -v _ph_refresh_wan_routes >/dev/null 2>&1; then
		_ph_refresh_wan_routes
	fi

	changed=0
	for entry in $MONITORED; do
		cfg=$(echo "$entry" | cut -d'|' -f1)
		dom=$(echo "$entry" | cut -d'|' -f2)
		fam=$(echo "$entry" | cut -d'|' -f3)
		name=$(echo "$entry" | cut -d'|' -f4)

		new_ip=$(resolve_addr "$dom" "$fam" "$DNS_SERVER")
		[ -n "$new_ip" ] || continue
		old_ip=""
		[ -f "$STATE_DIR/$cfg.ip" ] && old_ip=$(cat "$STATE_DIR/$cfg.ip")

		if [ "$new_ip" != "$old_ip" ]; then
			echo "$new_ip" > "$STATE_DIR/$cfg.ip"
			logger -t phantun "rule $name: peer IP changed $old_ip -> $new_ip"
			changed=1
		fi
	done
	if [ "$changed" = "1" ]; then
		logger -t phantun "restarting phantun due to peer IP change"
		/etc/init.d/phantun restart
	fi
done
