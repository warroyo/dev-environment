#!/usr/bin/env bash
# Loads the client lab's network details from a local file that is never
# committed. Source it, then:
#
#     if load_client_lab; then ...; fi
#
# The file is ~/.config/client-lab.env (override with CLIENT_LAB_ENV), mode
# 600, in the shape of provision/client-lab.env.example. It sets:
#
#   LAB_ZONE         DNS zone of the client lab, e.g. corp.example
#   LAB_SUBNET       the lab prefix forwarded out the OpenVPN tunnel
#   LAB_DNS          the lab's own resolver, reached through the tunnel
#   LAB_PROBE_NAME   a name inside LAB_ZONE that should always resolve
#   LAB_PROBE_ADDR   an address inside LAB_SUBNET that should always route
#
# Local DNS records (names the lab resolver does not serve) live beside it in
# ~/.config/client-lab.hosts (override with CLIENT_LAB_HOSTS), in the shape of
# provision/client-lab.hosts.example.
#
# The names and addresses are kept out of this public repo on purpose. Without
# the file, every client-lab step is skipped and the rest of a run carries on.
#
# Scripts run under sudo still read the invoking user's file: SUDO_USER's home
# wins over root's.

client_lab_home() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    # Tilde expansion rather than getent, which macOS does not have.
    eval "printf '%s\\n' ~${SUDO_USER}"
  else
    printf '%s\n' "$HOME"
  fi
}

CLIENT_LAB_ENV="${CLIENT_LAB_ENV:-$(client_lab_home)/.config/client-lab.env}"
CLIENT_LAB_HOSTS="${CLIENT_LAB_HOSTS:-$(client_lab_home)/.config/client-lab.hosts}"

load_client_lab() {
  [ -f "$CLIENT_LAB_ENV" ] || return 1
  # shellcheck disable=SC1090  # a local file, outside the repo by design
  . "$CLIENT_LAB_ENV"
  local missing="" var
  for var in LAB_ZONE LAB_SUBNET LAB_DNS; do
    [ -n "${!var:-}" ] || missing+=" ${var}"
  done
  if [ -n "$missing" ]; then
    printf 'client-lab: %s is missing:%s\n' "$CLIENT_LAB_ENV" "$missing" >&2
    return 1
  fi
  return 0
}
