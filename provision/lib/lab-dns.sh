#!/usr/bin/env bash
# Shared by the two macOS client bootstrap scripts. Source it, then call:
#
#     install_lab_resolver
#
# Idempotent, and a no-op on anything that isn't macOS.
#
# Installs a macOS split-DNS entry so names in the lab's internal zone resolve
# through the server's dnsmasq, and ONLY those names. Everything else keeps
# using whatever resolver the machine already had, so general browsing is
# untouched whether or not the lab is reachable.
#
# This is the client half of the routing set up by server-bootstrap.sh: the
# server forwards 10.47.0.0/16 out its OpenVPN tunnel and answers set.lab
# queries on port 5300, and this is what makes a browser able to type a
# hostname instead of an address. See docs/client-work-setup.md.

LAB_DNS_DOMAIN="set.lab"

# The server's LAN address, not the lab's own resolver, and not port 53.
#
# Pointing straight at the lab resolver on 53 is what this used to do, and it
# works right up until something in the path decides it owns port 53. A UniFi
# gateway does this to its VPN clients; hotel and airport APs do it to
# everyone. The interceptor answers in place of the address you asked for —
# NXDOMAIN with a root-server SOA, faster than the real resolver could reply —
# so the route looks perfect and only DNS is broken. Nothing on a borrowed
# network intercepts 5300.
#
# Must be a DHCP reservation or a static lease. If the server's LAN address
# changes, this file is what goes stale.
LAB_DNS_SERVER="${LAB_DNS_SERVER:-10.10.2.116}"
LAB_DNS_PORT="${LAB_DNS_PORT:-5300}"

install_lab_resolver() {
  [ "$(uname -s)" = "Darwin" ] || return 0

  local resolver_file="/etc/resolver/${LAB_DNS_DOMAIN}"

  # `timeout` matters more than it looks. This file applies unconditionally, so
  # off-network — no Teleport, not on the home LAN — every *.set.lab lookup goes
  # to an unreachable resolver and blocks until it gives up. The macOS default
  # makes that a multi-second hang on a typo'd hostname. Three seconds is long
  # enough for a 46ms round trip over the tunnel and short enough not to feel
  # like the machine has frozen.
  local desired
  desired="$(cat <<EOF
# Managed by dev-environment/provision — do not edit by hand.
# Split DNS: only ${LAB_DNS_DOMAIN} resolves here. See provision/lib/lab-dns.sh.
nameserver ${LAB_DNS_SERVER}
port ${LAB_DNS_PORT}
timeout 3
EOF
)"

  if [ -f "$resolver_file" ] && [ "$(sudo cat "$resolver_file" 2>/dev/null)" = "$desired" ]; then
    log "Lab split DNS already configured (${resolver_file})"
    return 0
  fi

  log "Configuring lab split DNS for *.${LAB_DNS_DOMAIN} -> ${LAB_DNS_SERVER}:${LAB_DNS_PORT}"
  sudo mkdir -p /etc/resolver
  printf '%s\n' "$desired" | sudo tee "$resolver_file" >/dev/null
  sudo chmod 644 "$resolver_file"

  # mDNSResponder picks the directory up on its own, but not always promptly,
  # and a stale negative cache entry outlives the change. Both commands are
  # cheap; skipping them is how "I added the file and it still doesn't resolve"
  # happens.
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true

  log "  Verify with: dscacheutil -q host -a name <host>.${LAB_DNS_DOMAIN}"
  log "  NOTE: dig and nslookup IGNORE /etc/resolver — they query a server"
  log "        directly and will report failure while everything else works."
  log "        The equivalent by hand is:"
  log "          dig -p ${LAB_DNS_PORT} @${LAB_DNS_SERVER} <host>.${LAB_DNS_DOMAIN}"
}
