#!/bin/sh
set -e

# Defense-in-depth L3/L4 egress lock, independent of Squid's L7 domain
# allowlist. Requires the container to run with cap_add: NET_ADMIN.
# Default-deny OUTPUT; only DNS, established/related, and 80/443 pass.
# Squid's dstdomain ACL (squid.conf) is what actually restricts *which*
# hosts get reached over 443 - this layer just stops other ports/protocols
# from being used to exfiltrate if Squid is ever misconfigured or bypassed.

iptables -F OUTPUT
iptables -P OUTPUT DROP

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS resolution - restricted to Docker's embedded resolver, which is what
# container DNS actually uses (it forwards upstream itself). Allowing
# --dport 53 to any host would leave a DNS-tunneling exfil channel open.
iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d 127.0.0.11 --dport 53 -j ACCEPT

# Squid itself is the only thing allowed to open new 80/443 connections out
# to the internet; Squid's http_access rules gate which domains. Owner-match
# on the squid uid (proxy) so a foothold elsewhere in this container can't
# use some other process to egress on these ports. Falls back to a port-only
# rule if xt_owner isn't available in the runtime kernel.
if iptables -A OUTPUT -p tcp --dport 80 -m owner --uid-owner proxy -j ACCEPT 2>/dev/null; then
  iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner proxy -j ACCEPT
else
  echo "entrypoint.sh: xt_owner unavailable, falling back to port-only 80/443 egress rule (less strict)" >&2
  iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
fi

iptables -A OUTPUT -j DROP

# The access log dir is host-mounted (docker-compose.yml); make sure the
# user squid actually drops to (proxy) can write into it.
mkdir -p /var/log/squid
chown -R proxy:proxy /var/log/squid

exec entrypoint.sh "$@"
