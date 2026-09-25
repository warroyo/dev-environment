#!/usr/bin/env bash
# Shared by the two macOS client bootstrap scripts. Source it, then call:
#
#     install_lab_resolver
#
# To point it somewhere other than the default, set LAB_DNS_SERVER first —
# lab_dns_server_over_tailscale below is how the personal client gets a value
# without hardcoding one.
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

# Not the lab's own resolver, and not port 53.
#
# Pointing straight at the lab resolver on 53 is what this used to do, and it
# works right up until something in the path decides it owns port 53. A UniFi
# gateway does this to its VPN clients; hotel and airport APs do it to
# everyone. The interceptor answers in place of the address you asked for —
# NXDOMAIN with a root-server SOA, faster than the real resolver could reply —
# so the route looks perfect and only DNS is broken. Nothing on a borrowed
# network intercepts 5300.
#
# The tailnet path is immune to that on its own — those queries ride inside
# WireGuard, so a borrowed network never sees a port-53 packet to steal — but
# the port stays 5300 for both paths anyway. One dnsmasq instance holds one
# port, and a second instance on 53 for the tailnet alone would buy nothing.
#
# WHICH ADDRESS depends on how the machine reaches the server, so the caller
# decides:
#
#   work     — the server's LAN address, over the split-tunnel OpenVPN or
#              Teleport path. Must be a DHCP reservation or a static lease; if
#              it changes, this default is what goes stale.
#   personal — the server's tailnet address, discovered at provision time by
#              lab_dns_server_over_tailscale, so nothing is written down.
#
# The LAN address is the default because it is the one that cannot be
# discovered.
#
# LAB_DNS_SERVER may hold several addresses, space-separated, and each becomes
# its own `nameserver` line. mDNSResponder falls through to the next one when a
# server does not answer, which is how the personal client covers both paths:
# tailnet first, LAN second, so the zone still resolves at home with Tailscale
# off.
LAB_DNS_LAN_SERVER="10.10.2.116"
LAB_DNS_SERVER="${LAB_DNS_SERVER:-${LAB_DNS_LAN_SERVER}}"
LAB_DNS_PORT="${LAB_DNS_PORT:-5300}"

# Print the server's tailnet IPv4 address, for use as LAB_DNS_SERVER, or return
# non-zero. Takes the server's tailnet hostname.
#
# Asking `tailscale ip -4 <peer>` is what keeps the address out of the repo: it
# resolves the peer from this machine's own view of the tailnet, so a re-run
# picks up a changed address by itself.
lab_dns_server_over_tailscale() {
  local peer="$1" cli ip

  # These bootstraps are non-interactive bash, so the `tailscale` alias that
  # 40_path.sh defines for interactive shells does not exist here. The GUI app
  # is the normal way to run Tailscale on a Mac and never puts its bundled CLI
  # on PATH, so look inside the bundle before giving up.
  if command -v tailscale >/dev/null 2>&1; then
    cli="tailscale"
  elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    cli="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  elif [ -x "${HOME}/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    cli="${HOME}/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  else
    return 1
  fi

  ip="$("$cli" ip -4 "$peer" 2>/dev/null | head -n1)"

  # A sanity check, not validation: tailnet addresses live in 100.64.0.0/10,
  # and anything else here would write a resolver file pointing at a stranger.
  # Being logged out and naming an unknown peer both land here.
  case "$ip" in
    100.*) printf '%s\n' "$ip" ;;
    *)     return 1 ;;
  esac
}

install_lab_resolver() {
  [ "$(uname -s)" = "Darwin" ] || return 0

  local resolver_file="/etc/resolver/${LAB_DNS_DOMAIN}"

  # `timeout` matters more than it looks. This file applies unconditionally, so
  # off-network — no Teleport, not on the home LAN — every *.set.lab lookup goes
  # to an unreachable resolver and blocks until it gives up. The macOS default
  # makes that a multi-second hang on a typo'd hostname. Three seconds is long
  # enough for a 46ms round trip over the tunnel and short enough not to feel
  # like the machine has frozen.
  local desired server nameservers=""
  for server in $LAB_DNS_SERVER; do
    nameservers+="nameserver ${server}"$'\n'
  done
  desired="$(cat <<EOF
# Managed by dev-environment/provision — do not edit by hand.
# Split DNS: only ${LAB_DNS_DOMAIN} resolves here. See provision/lib/lab-dns.sh.
${nameservers%$'\n'}
port ${LAB_DNS_PORT}
timeout 3
EOF
)"

  if [ -f "$resolver_file" ] && [ "$(sudo cat "$resolver_file" 2>/dev/null)" = "$desired" ]; then
    log "Lab split DNS already configured (${resolver_file})"
    return 0
  fi

  log "Configuring lab split DNS for *.${LAB_DNS_DOMAIN} -> ${LAB_DNS_SERVER} (port ${LAB_DNS_PORT})"
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
  for server in $LAB_DNS_SERVER; do
    log "          dig -p ${LAB_DNS_PORT} @${server} <host>.${LAB_DNS_DOMAIN}"
  done
}
