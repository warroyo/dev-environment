#!/usr/bin/env bash
# Shared by the two macOS client bootstrap scripts. Source it, then call:
#
#     install_lab_resolver
#
# Idempotent, and a no-op on anything that isn't macOS.
#
# Installs a macOS split-DNS entry so names in the lab's internal zone resolve
# through the lab's own resolver, and ONLY those names. Everything else keeps
# using whatever resolver the machine already had, so general browsing is
# untouched whether or not the lab is reachable.
#
# This is the client half of the routing set up by server-bootstrap.sh: the
# server forwards 10.47.0.0/16 and the lab resolver out its OpenVPN tunnel, and
# this is what makes a browser able to type a hostname instead of an address.
# See docs/client-work-setup.md.

LAB_DNS_DOMAIN="set.lab"
LAB_DNS_SERVER="172.21.0.90"

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
timeout 3
EOF
)"

  if [ -f "$resolver_file" ] && [ "$(sudo cat "$resolver_file" 2>/dev/null)" = "$desired" ]; then
    log "Lab split DNS already configured (${resolver_file})"
    return 0
  fi

  log "Configuring lab split DNS for *.${LAB_DNS_DOMAIN} -> ${LAB_DNS_SERVER}"
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
}
