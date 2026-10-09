#!/bin/sh
# The image's entrypoint. It starts as root, sets the firewall that
# bounds what code past the policy reaches beyond the beamlet, and
# runs the command, which the release drops to `beamlet` with no
# capabilities (rel/env.sh.eex).
#
# Outbound, the rules allow loopback, replies to inbound connections,
# DNS to the resolvers in /etc/resolv.conf, the ICMPv6 that IPv6
# needs, the hosts in BEAMLET_HTTP_ALLOW, and TCP to public addresses
# except port 25. Everything else is rejected, TCP with a reset, so a
# refused connection fails at once instead of waiting out a timeout.
# The private ranges are req_ssrf's, the ones the Host.HTTP guard
# refuses. Only the filter table's OUTPUT chain is touched: Docker
# keeps its embedded DNS in the nat table.
set -euf

V4_PRIVATE="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 168.63.129.16/32
169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24
192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4
240.0.0.0/4"

# IPv6 outside 2000::/3 is refused whole; these are the reserved
# blocks inside it.
V6_RESERVED="2001::/23 2001:db8::/32 2002::/16 3fff::/20"

OPT_OUT="or set BEAMLET_FIREWALL=off to start without the rules."

fail() {
  echo "beamlet: $*" >&2
  exit 1
}

# Fly mounts a fresh volume owned by root, and nothing hands it to
# `beamlet` when the image starts as root. Only the directory itself:
# root never walks a tree `beamlet` can write.
data_dir="${BEAMLET_DATA_DIR:-/data}"

if [ "$(id -u)" = 0 ] && [ -d "$data_dir" ] && [ "$(stat -c %u "$data_dir")" = 0 ]; then
  chown beamlet:beamlet "$data_dir"
fi

case "${BEAMLET_FIREWALL:-on}" in
  on) ;;
  off)
    echo "beamlet: BEAMLET_FIREWALL=off, starting without firewall rules"
    exec "$@"
    ;;
  *) fail "BEAMLET_FIREWALL must be on or off, got: $BEAMLET_FIREWALL" ;;
esac

if [ "$(id -u)" != 0 ]; then
  fail "the image starts as root to set its firewall rules, then runs as the beamlet user. Remove --user from docker run, $OPT_OUT"
fi

if ! error=$(iptables -S OUTPUT 2>&1); then
  fail "setting the firewall rules needs the NET_ADMIN capability. Add --cap-add NET_ADMIN to docker run, $OPT_OUT ($error)"
fi

# Without ip6tables the rules cannot cover IPv6, which matters only
# when the container has an IPv6 address beyond loopback.
if ip6tables -S OUTPUT >/dev/null 2>&1; then
  ipv6=on
elif grep -qv ' lo$' /proc/net/if_inet6 2>/dev/null; then
  fail "ip6tables cannot set rules, and the container has an IPv6 address the rules would leave open. $OPT_OUT"
else
  ipv6=off
fi

# Names resolve once, now, before any rule is in place.
allow_v4=""
allow_v6=""

for entry in $(echo "${BEAMLET_HTTP_ALLOW:-}" | tr ',' ' '); do
  case $entry in
    *[!0-9A-Za-z.:/_-]*)
      fail "BEAMLET_HTTP_ALLOW takes host names, IP addresses and CIDR blocks, got: $entry"
      ;;
    *:*) allow_v6="$allow_v6 $entry" ;;
    *[!0-9./]*)
      addresses=$(getent ahosts "$entry" | awk '{ print $1 }' | sort -u)
      [ -n "$addresses" ] || fail "BEAMLET_HTTP_ALLOW: $entry does not resolve"

      for address in $addresses; do
        case $address in
          *:*) allow_v6="$allow_v6 $address" ;;
          *) allow_v4="$allow_v4 $address" ;;
        esac
      done
      ;;
    *) allow_v4="$allow_v4 $entry" ;;
  esac
done

resolvers=$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)

# open_chain TOOL ALLOWED RESOLVERS: the head of the chain both
# families share, up to the private ranges.
open_chain() {
  $1 -F OUTPUT
  $1 -A OUTPUT -o lo -j ACCEPT
  $1 -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  for resolver in $3; do
    $1 -A OUTPUT -d "$resolver" -p udp --dport 53 -j ACCEPT
    $1 -A OUTPUT -d "$resolver" -p tcp --dport 53 -j ACCEPT
  done

  for host in $2; do
    $1 -A OUTPUT -d "$host" -p tcp -j ACCEPT 2>/dev/null ||
      fail "BEAMLET_HTTP_ALLOW: $host is not an IP address or CIDR block"
  done
}

# close_chain TOOL: the end of the chain both families share.
close_chain() {
  $1 -A OUTPUT -p tcp --dport 25 -j REJECT --reject-with tcp-reset
  $1 -A OUTPUT -p tcp -j ACCEPT
  $1 -A OUTPUT -j REJECT
}

open_chain iptables "$allow_v4" "$(echo "$resolvers" | grep -v :)"

for block in $V4_PRIVATE; do
  iptables -A OUTPUT -d "$block" -p tcp -j REJECT --reject-with tcp-reset
  iptables -A OUTPUT -d "$block" -j REJECT
done

close_chain iptables

if [ $ipv6 = on ]; then
  open_chain ip6tables "$allow_v6" "$(echo "$resolvers" | grep :)"

  for type in router-solicitation neighbour-solicitation neighbour-advertisement 143; do
    ip6tables -A OUTPUT -p ipv6-icmp --icmpv6-type $type -j ACCEPT
  done

  ip6tables -A OUTPUT ! -d 2000::/3 -p tcp -j REJECT --reject-with tcp-reset
  ip6tables -A OUTPUT ! -d 2000::/3 -j REJECT

  for block in $V6_RESERVED; do
    ip6tables -A OUTPUT -d "$block" -p tcp -j REJECT --reject-with tcp-reset
    ip6tables -A OUTPUT -d "$block" -j REJECT
  done

  close_chain ip6tables
fi

echo "beamlet: firewall set, outbound to public TCP${BEAMLET_HTTP_ALLOW:+ and $BEAMLET_HTTP_ALLOW}"
exec "$@"
