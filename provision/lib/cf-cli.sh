#!/usr/bin/env bash
# Installs the client lab's Tanzu cf CLI into ~/.local/bin. Source it, then:
#
#     install_cf_cli
#
# The foundation serves its own cf build without auth: a tarball holding
# `cf10` and a `cf` symlink to it. Its URL names the lab, so it comes from
# LAB_CF_CLI_URL in ~/.config/client-lab.env (lib/client-lab.sh), never from
# this public repo. Without it, or without the tunnel, this is skipped.
#
# The download can't be verified: the foundation's certificate is
# self-signed and there is no checksum file. It only ever goes over the
# client-lab tunnel.
#
# Only installed when missing. To upgrade, delete ~/.local/bin/cf10 and
# ~/.local/bin/cf and run it again.
#
# To run just this step:
#
#     bash -c '. provision/lib/client-lab.sh; . provision/lib/cf-cli.sh; load_client_lab && install_cf_cli'

install_cf_cli() {
  local dest="$HOME/.local/bin" tmp
  if [ -z "${LAB_CF_CLI_URL:-}" ]; then
    echo "cf-cli: LAB_CF_CLI_URL not set in ${CLIENT_LAB_ENV:-client-lab.env}: skipping"
    return 0
  fi
  if [ -x "$dest/cf10" ]; then
    echo "cf-cli: already installed ($("$dest/cf10" version 2>/dev/null))"
    return 0
  fi
  tmp="$(mktemp -d)"
  if curl -fsSLk --max-time 120 -o "$tmp/cf.tgz" "$LAB_CF_CLI_URL" \
    && tar -xzf "$tmp/cf.tgz" -C "$tmp" cf10; then
    mkdir -p "$dest"
    install -m 755 "$tmp/cf10" "$dest/cf10"
    ln -sfn cf10 "$dest/cf"
    echo "cf-cli: installed $("$dest/cf10" version 2>/dev/null)"
  else
    # Not fatal: nothing else depends on it.
    echo "cf-cli: WARNING: download from LAB_CF_CLI_URL failed. Is the client-lab tunnel up?"
  fi
  rm -rf "$tmp"
}
