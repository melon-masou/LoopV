#!/bin/sh
# Usage:
#   tproxy-setup.sh
#   tproxy-setup.sh reload-firewall [mode]

# Deployment-specific values are read from drop-in env files
for env_file in /etc/loopv/tproxy.env.d/*.env; do
  [ -f "$env_file" ] && . "$env_file"
done

# tproxy/redirect ports.
TPROXY_PORT="${TPROXY_PORT:-1393}"
REDIR_PORT="${REDIR_PORT:-1394}"
# Whether forwarded TCP uses TPROXY (mangle) or REDIRECT. UDP always TPROXY.
TCP_TPROXY="${TCP_TPROXY:-true}"

# Packets marked with ROUTE_FW_MASK are policy-routed to local loopback so the
# tproxy socket can receive packets without changing their original destination.
ROUTE_FW_MASK="1"
ROUTE_TABLE="100"

# When not "true", no firewall chains are built at all.
FIREWALL_ENABLE="${FIREWALL_ENABLE:-false}"
# Firewall policy (only applies when FIREWALL_ENABLE=true) for traffic not
# matched by the always-allow prefilter: allow or deny.
FIREWALL_MODE="${FIREWALL_MODE:-deny}"
# Trusted sources, always allowed through (and on to tproxy). Split by space or newline.
FIREWALL_ALLOW_CIDR="${FIREWALL_ALLOW_CIDR:-172.21.200.0/24}"

# Explicit inbound port forwarding. Rules use this format:
#   protocol:port[,port-range...]=target-ip;...
PORT_FORWARD_RULES="${PORT_FORWARD_RULES:-}"
PORT_FORWARD_IN_INTERFACE="${PORT_FORWARD_IN_INTERFACE:-}"
PORT_FORWARD_SNAT="${PORT_FORWARD_SNAT:-false}"

# Networks that use this host as gateway and need LAN-destination bypass/SNAT.
PROXIED_SRC_CIDR="${PROXIED_SRC_CIDR:-}"

# Destination networks forwarded directly, not sent to tproxy.
# These traffic will be SNAT if SNAT_FALLBACK enabled.
# Split by space or newline.
DIRECT_DST_CIDR="${DIRECT_DST_CIDR:-}"

# Fallback SNAT: MASQUERADE the leftover non-proxied traffic from PROXIED_SRC_CIDR,
# so replies return through the same path as the outgoing traffic.
SNAT_FALLBACK="${SNAT_FALLBACK:-true}"
# Outbound interfaces the fallback SNAT is restricted to. Leave empty to
# MASQUERADE on any egress. Split by space or newline.
SNAT_OUT_INTERFACE="${SNAT_OUT_INTERFACE:-}"

# Fake-ip range the proxy maps domains to. Traffic from localhost to this range 
# will be marked to prevent entering proxy again.
# FAKE_IP_CIDR="${FAKE_IP_CIDR:-}"

# Reserved/special-use ranges that should never be transparently proxied.
RESERVED_CIDR="${RESERVED_CIDR:-
0.0.0.0/8
127.0.0.0/8
169.254.0.0/16
224.0.0.0/4
240.0.0.0/4
255.255.255.255/32
}"

# iptables chain names
PROXY_CHAIN="${PROXY_CHAIN:-TPROXY-PREROUTE}"
FIREWALL_CHAIN="${FIREWALL_CHAIN:-TPROXY-FIREWALL}"
FIREWALL_APPLY_CHAIN="${FIREWALL_APPLY_CHAIN:-TPROXY-FIREWALL-APPLY}"
PORT_FORWARD_CHAIN="LOOPV-PORT-FORWARD"

if [ -z "$IPTABLES" ]; then
  if [ -x /sbin/iptables ]; then
    IPTABLES=/sbin/iptables
  elif [ -x /usr/sbin/iptables ]; then
    IPTABLES=/usr/sbin/iptables
  else
    echo "iptables not found"
    exit 1
  fi
fi
IP="${IP:-/sbin/ip}"
SYSCTL="${SYSCTL:-/sbin/sysctl}"

set -e

config_error() {
  echo "Invalid port-forward config: $*" >&2
  return 1
}

validate_port_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_port_list() {
  remaining_ports="$1"
  port_count=0

  case "$remaining_ports" in
    ''|,*|*,|*,,*) return 1 ;;
  esac

  while [ -n "$remaining_ports" ]; do
    case "$remaining_ports" in
      *,*)
        port_part=${remaining_ports%%,*}
        remaining_ports=${remaining_ports#*,}
        ;;
      *)
        port_part=$remaining_ports
        remaining_ports=
        ;;
    esac

    case "$port_part" in
      *-*)
        range_start=${port_part%%-*}
        range_end=${port_part#*-}
        case "$range_end" in
          *-*) return 1 ;;
        esac
        validate_port_number "$range_start" || return 1
        validate_port_number "$range_end" || return 1
        [ "$range_start" -le "$range_end" ] || return 1
        port_count=$((port_count + 2))
        ;;
      *)
        validate_port_number "$port_part" || return 1
        port_count=$((port_count + 1))
        ;;
    esac
  done

  # iptables multiport accepts at most 15 ports; a range consumes two slots.
  [ "$port_count" -le 15 ]
}

validate_ipv4_address() {
  case "$1" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac

  previous_ifs=$IFS
  IFS=.
  set -- $1
  IFS=$previous_ifs
  [ "$#" -eq 4 ] || return 1

  for octet in "$@"; do
    case "$octet" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$octet" -le 255 ] || return 1
  done
}

for_each_port_forward_rule() {
  callback="$1"
  remaining_rules=$PORT_FORWARD_RULES

  case "$remaining_rules" in
    ';'*|*';'|*';;'*) config_error "empty rule" ;;
  esac

  while [ -n "$remaining_rules" ]; do
    case "$remaining_rules" in
      *';'*)
        rule=${remaining_rules%%;*}
        remaining_rules=${remaining_rules#*;}
        ;;
      *)
        rule=$remaining_rules
        remaining_rules=
        ;;
    esac

    protocol=${rule%%:*}
    rule_body=${rule#*:}
    [ "$rule_body" != "$rule" ] || config_error "missing ':' in '$rule'"

    ports=${rule_body%%=*}
    target=${rule_body#*=}
    [ "$target" != "$rule_body" ] || config_error "missing '=' in '$rule'"
    case "$target" in
      *=*) config_error "too many '=' characters in '$rule'" ;;
    esac

    case "$protocol" in
      tcp|udp) ;;
      *) config_error "unsupported protocol '$protocol'" ;;
    esac
    validate_port_list "$ports" || config_error "invalid port list '$ports'"
    validate_ipv4_address "$target" || config_error "invalid target IPv4 address '$target'"

    "$callback" "$protocol" "$ports" "$target"
  done
}

validate_port_forward_rule() {
  :
}

if [ -n "$PORT_FORWARD_RULES" ]; then
  [ -n "$PORT_FORWARD_IN_INTERFACE" ] || config_error "PORT_FORWARD_IN_INTERFACE is required"
  case "$PORT_FORWARD_SNAT" in
    true|false) ;;
    *) config_error "PORT_FORWARD_SNAT must be true or false" ;;
  esac
  $IP link show dev "$PORT_FORWARD_IN_INTERFACE" >/dev/null 2>&1 || config_error "interface '$PORT_FORWARD_IN_INTERFACE' does not exist"
  for_each_port_forward_rule validate_port_forward_rule
fi

if [ -z "$PROXIED_SRC_CIDR" ] && [ -n "$DIRECT_DST_CIDR" ]; then
  echo "DIRECT_DST_CIDR requires PROXIED_SRC_CIDR"
  exit 1
fi

if [ "$FIREWALL_ENABLE" = "true" ]; then
  case "$FIREWALL_MODE" in
    allow|deny) ;;
    *) echo "Unknown firewall mode: $FIREWALL_MODE (expected allow|deny)" >&2; exit 1 ;;
  esac
fi

if [ -n "$PORT_FORWARD_RULES" ]; then
  $SYSCTL -w net.ipv4.ip_forward=1 >/dev/null
fi

# Rebuild only the firewall policy chain (allow/deny)
reload_firewall() {
  mode="${1:-$FIREWALL_MODE}"
  $IPTABLES -t mangle -N "$FIREWALL_APPLY_CHAIN" 2>/dev/null || true
  $IPTABLES -t mangle -F "$FIREWALL_APPLY_CHAIN"
  case "$mode" in
    allow)   $IPTABLES -t mangle -A "$FIREWALL_APPLY_CHAIN" -j RETURN ;;
    deny)    $IPTABLES -t mangle -A "$FIREWALL_APPLY_CHAIN" -j DROP ;;
    *) echo "Unknown firewall mode: $mode (expected allow|deny)"; exit 1 ;;
  esac
  echo "Firewall mode: $mode"
}

# Subcommand: only reload the firewall policy chain, then exit.
if [ "$1" = "reload-firewall" ]; then
  if [ "$FIREWALL_ENABLE" != "true" ]; then
    echo "FIREWALL_ENABLE is not true; firewall chains are not built."
    exit 0
  fi
  reload_firewall "${2:-$FIREWALL_MODE}"
  exit 0
fi

while $IP rule del fwmark $ROUTE_FW_MASK table $ROUTE_TABLE 2>/dev/null; do
  :
done
$IP rule add fwmark $ROUTE_FW_MASK table $ROUTE_TABLE
$IP route replace local default dev lo table $ROUTE_TABLE

# Rebuild tables from scratch
$IPTABLES -t nat -F
$IPTABLES -t mangle -F
$IPTABLES -t nat -X
$IPTABLES -t mangle -X

# The nat chain is used for TCP REDIRECT
# the mangle chain is used for TPROXY and firewalling.
$IPTABLES -t nat -N $PROXY_CHAIN
$IPTABLES -t mangle -N $PROXY_CHAIN

if [ "$FIREWALL_ENABLE" = "true" ]; then
  $IPTABLES -t mangle -N $FIREWALL_CHAIN
  $IPTABLES -t mangle -N $FIREWALL_APPLY_CHAIN
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -i lo -j RETURN
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -m addrtype --src-type LOCAL --dst-type LOCAL -j RETURN
  # Established/related is allowed before the policy, so the VM's own outbound
  # replies (e.g. the proxy's) are never dropped or forwarded, in any mode.
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for cidr in $FIREWALL_ALLOW_CIDR; do
    $IPTABLES -t mangle -A $FIREWALL_CHAIN -s "$cidr" -j RETURN
  done
fi

apply_port_forward_rule() {
  protocol="$1"
  ports="$2"
  target="$3"
  iptables_ports=$(printf '%s' "$ports" | tr '-' ':')

  $IPTABLES -t nat -A "$PORT_FORWARD_CHAIN" -p "$protocol" -m multiport --dports "$iptables_ports" -j DNAT --to-destination "$target"

  if [ "$FIREWALL_ENABLE" = "true" ]; then
    $IPTABLES -t mangle -A "$FIREWALL_CHAIN" -i "$PORT_FORWARD_IN_INTERFACE" -m addrtype --dst-type LOCAL -p "$protocol" -m multiport --dports "$iptables_ports" -j RETURN
  fi

  if [ "$PORT_FORWARD_SNAT" = "true" ]; then
    $IPTABLES -t nat -A POSTROUTING -d "$target" -p "$protocol" -m multiport --dports "$iptables_ports" -m conntrack --ctstate DNAT -j MASQUERADE
  fi
}

if [ -n "$PORT_FORWARD_RULES" ]; then
  $IPTABLES -t nat -N "$PORT_FORWARD_CHAIN"
  $IPTABLES -t nat -A PREROUTING -i "$PORT_FORWARD_IN_INTERFACE" -m addrtype --dst-type LOCAL -j "$PORT_FORWARD_CHAIN"
  for_each_port_forward_rule apply_port_forward_rule
fi

if [ "$FIREWALL_ENABLE" = "true" ]; then
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -j $FIREWALL_APPLY_CHAIN
  $IPTABLES -t mangle -I PREROUTING 1 -j $FIREWALL_CHAIN
fi

# Port-forwarded connections belong to their DNAT target, not the transparent proxy.
$IPTABLES -t nat -A $PROXY_CHAIN -m conntrack --ctstate DNAT -j RETURN
$IPTABLES -t mangle -A $PROXY_CHAIN -m conntrack --ctstate DNAT -j RETURN

# Never proxy traffic whose destination is the router itself
$IPTABLES -t nat -A $PROXY_CHAIN -m addrtype --dst-type LOCAL -j RETURN
$IPTABLES -t mangle -A $PROXY_CHAIN -m addrtype --dst-type LOCAL -j RETURN
# Never proxy broadcast traffic
$IPTABLES -t nat -A $PROXY_CHAIN -m addrtype --dst-type BROADCAST -j RETURN
$IPTABLES -t mangle -A $PROXY_CHAIN -m addrtype --dst-type BROADCAST -j RETURN
$IPTABLES -t nat -A $PROXY_CHAIN -m pkttype --pkt-type broadcast -j RETURN
$IPTABLES -t mangle -A $PROXY_CHAIN -m pkttype --pkt-type broadcast -j RETURN

# Skip tproxy for these CIDRs. RETURN leaves PROXY_CHAIN and lets the next
# PREROUTING/routing/NAT stage handle the packet.
for cidr in $RESERVED_CIDR; do
  $IPTABLES -t nat -A $PROXY_CHAIN -d "$cidr" -j RETURN
  $IPTABLES -t mangle -A $PROXY_CHAIN -d "$cidr" -j RETURN
done

for cidr in $PROXIED_SRC_CIDR; do
  $IPTABLES -t nat -A $PROXY_CHAIN -d "$cidr" -j RETURN
  $IPTABLES -t mangle -A $PROXY_CHAIN -d "$cidr" -j RETURN
done

for cidr in $DIRECT_DST_CIDR; do
  $IPTABLES -t nat -A $PROXY_CHAIN -d "$cidr" -j RETURN
  $IPTABLES -t mangle -A $PROXY_CHAIN -d "$cidr" -j RETURN
done

# TCP from forwarded clients. TPROXY/REDIRECT
if [ "$TCP_TPROXY" = "true" ]; then
  $IPTABLES -t mangle -A $PROXY_CHAIN -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $ROUTE_FW_MASK
  $IPTABLES -t mangle -A PREROUTING -p tcp -j $PROXY_CHAIN
else
  $IPTABLES -t nat -A $PROXY_CHAIN -p tcp -j REDIRECT --to-port $REDIR_PORT
  $IPTABLES -t nat -A PREROUTING -p tcp -j $PROXY_CHAIN
fi

# UDP from forwarded clients always uses TPROXY
$IPTABLES -t mangle -A $PROXY_CHAIN -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $ROUTE_FW_MASK
$IPTABLES -t mangle -A PREROUTING -p udp -j $PROXY_CHAIN

# Local OUTPUT is intentionally not intercepted. Keep these disabled unless this
# gateway host itself needs transparent fake-ip handling.
# $IPTABLES -t nat -A OUTPUT -p tcp -d $FAKE_IP_CIDR -j REDIRECT --to-port $REDIR_PORT
# $IPTABLES -t mangle -A OUTPUT -p udp -d $FAKE_IP_CIDR -j MARK --set-mark $ROUTE_FW_MASK

# SNAT for non-proxied client traffic
if [ "$SNAT_FALLBACK" = "true" ]; then
  for cidr in $PROXIED_SRC_CIDR; do
    if [ -n "$SNAT_OUT_INTERFACE" ]; then
      for iface in $SNAT_OUT_INTERFACE; do
        $IPTABLES -t nat -A POSTROUTING -s "$cidr" -o "$iface" -j MASQUERADE
      done
    else
      $IPTABLES -t nat -A POSTROUTING -s "$cidr" -j MASQUERADE
    fi
  done
fi

# Fill the firewall policy chain according to FIREWALL_MODE.
if [ "$FIREWALL_ENABLE" = "true" ]; then
  reload_firewall "$FIREWALL_MODE"
fi

echo "Finished set up"
echo "TABLE mangle:"
$IPTABLES -t mangle -S
echo "TABLE nat:"
$IPTABLES -t nat -S
echo "Route table:"
$IP route
