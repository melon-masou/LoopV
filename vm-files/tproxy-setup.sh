#!/bin/sh

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

# Source-based firewall. When true, only FIREWALL_ALLOW_CIDR CIDRs may use this gateway.
# Split by space or newline.
FIREWALL_ENABLE="${FIREWALL_ENABLE:-false}"
FIREWALL_ALLOW_CIDR="${FIREWALL_ALLOW_CIDR:-172.21.200.0/24}"

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

if [ -z "$PROXIED_SRC_CIDR" ] && [ -n "$DIRECT_DST_CIDR" ]; then
  echo "DIRECT_DST_CIDR requires PROXIED_SRC_CIDR"
  exit 1
fi

set -e

$IP rule add fwmark $ROUTE_FW_MASK table $ROUTE_TABLE
$IP route add local default dev lo table $ROUTE_TABLE

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
  # Allow local/established traffic before enforcing client source allowlists.
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -i lo -j RETURN
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -m addrtype --src-type LOCAL --dst-type LOCAL -j RETURN
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for cidr in $FIREWALL_ALLOW_CIDR; do
    $IPTABLES -t mangle -A $FIREWALL_CHAIN -s "$cidr" -j RETURN
  done
  $IPTABLES -t mangle -A $FIREWALL_CHAIN -j DROP
  $IPTABLES -t mangle -I PREROUTING 1 -j $FIREWALL_CHAIN
fi

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

$IPTABLES -t filter -D INPUT -j $FIREWALL_CHAIN 2>/dev/null || true
$IPTABLES -t filter -F $FIREWALL_CHAIN 2>/dev/null || true
$IPTABLES -t filter -X $FIREWALL_CHAIN 2>/dev/null || true

echo "Finished set up"
echo "TABLE mangle:"
$IPTABLES -t mangle -S
echo "TABLE nat:"
$IPTABLES -t nat -S
echo "Route table:"
$IP route
