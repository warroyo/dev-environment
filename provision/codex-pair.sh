#!/usr/bin/env bash
#
# One-shot pairing helper for driving Codex from the ChatGPT app
# (docs/server-setup.md §10).
#
#   ./provision/codex-pair.sh
#
# server-bootstrap.sh already installs the standalone CLI, the AppArmor profile
# the sandbox needs, and codex-app-server.service, and it already tries to
# enroll this machine for remote control. What it cannot do is the half that
# needs a human holding a phone: `codex login`, and typing a pairing code that
# expires in minutes. This script is that half, plus the checks that turn each
# way it can fail into a sentence instead of a stack of unrelated errors.
#
# Re-runnable: run it again to pair another device, or after a `codex logout`.
# Pairing is per MACHINE, not per session — once this succeeds, every session
# started here (by codex-open, by the Telegram bot's /cx_open, or by hand with
# `codex --remote unix://`) shows up in the app with nothing else to do.
set -euo pipefail

CODEX="${CODEX_BIN:-$HOME/.local/bin/codex}"
UNIT="codex-app-server.service"

log()  { printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  # Everything here is about ~/.codex — under sudo that is /root's, which is
  # not the account the daemon or any session runs as.
  die "run this as your normal user, not with sudo (it reads \$HOME/.codex)"
fi

# ---------------------------------------------------------------------------
log "Checking the Codex install"
[ -x "$CODEX" ] || die "no codex at ${CODEX} — run ./provision/server-bootstrap.sh"
# `codex` on PATH is not enough. The daemon starts and self-updates app-server
# from the installer-managed copy at this fixed path, so an npm-installed Codex
# gets all the way here and then cannot be driven from a phone at all.
if [ ! -x "$HOME/.codex/packages/standalone/current/codex" ]; then
  die "this is not the standalone Codex build — the app-server daemon cannot
       start from it. Re-run ./provision/server-bootstrap.sh, which installs
       the right one and removes an npm-managed copy."
fi
info "$("$CODEX" --version 2>/dev/null || echo 'version unknown')"

# ---------------------------------------------------------------------------
log "Checking the app-server daemon"
if ! daemon_json="$("$CODEX" app-server daemon version 2>&1)"; then
  info "not running — starting it"
  "$CODEX" app-server daemon start >/dev/null 2>&1 || \
    die "could not start the daemon: $("$CODEX" app-server daemon start 2>&1 | head -n3)"
  daemon_json="$("$CODEX" app-server daemon version 2>&1 || true)"
fi
case "$daemon_json" in
  *'"status":"running"'*) info "running" ;;
  *) die "the daemon is not running: ${daemon_json}" ;;
esac
if ! systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
  info "WARNING: ${UNIT} is not enabled, so the daemon will not come back after"
  info "         a reboot. Fix with ./provision/server-bootstrap.sh"
fi

# ---------------------------------------------------------------------------
log "Checking login"
# There is no `codex whoami`, and auth.json is not a documented interface, so
# its mere presence is all this can honestly check. A stale or revoked token
# still gets caught below, where enrollment fails.
[ -f "$HOME/.codex/auth.json" ] || die "not logged in — run: codex login"
info "credentials present (~/.codex/auth.json)"

# ---------------------------------------------------------------------------
log "Enrolling this machine for remote control"
# `remote-control start` EXITS 0 whether or not the connection came up, and
# prints two different things depending on whether stdin is a terminal (a human
# "Error: ..." line with one, JSON without). So: redirect stdin, read the
# status field, and never trust the exit code.
rc_out="$("$CODEX" remote-control start --json 2>&1 </dev/null || true)"
case "$rc_out" in
  *'"status":"connected"'*)
    info "connected as $(printf '%s' "$rc_out" | sed -n 's/.*"serverName":"\([^"]*\)".*/\1/p')" ;;
  *)
    printf '\n%s\n' "$rc_out"
    if printf '%s' "$rc_out" | grep -qi 'multi-factor'; then
      die "this account has no MFA, and enrollment requires it. Enable 2FA on
       the ChatGPT account, run 'codex login' again, then re-run this script."
    fi
    die "remote control did not connect (see above). If it mentions
       authentication, 'codex login' and try again."
    ;;
esac

# ---------------------------------------------------------------------------
log "Pairing code"
pair_out="$("$CODEX" remote-control pair 2>&1 </dev/null || true)"
if printf '%s' "$pair_out" | grep -qi 'multi-factor'; then
  printf '\n%s\n' "$pair_out"
  die "enable 2FA on the ChatGPT account, run 'codex login', then re-run this."
fi
printf '\n%s\n\n' "$pair_out"
info "Enter that code in the ChatGPT app to pair $(hostname -s)."
info "It is short-lived — re-run this script if it expires before you get there."
printf '\n'
info "After pairing, start a session any of these ways and it appears in the app:"
info "  Telegram   /cx_open <dir>"
info "  SSH        codex-open <dir>      (alias: cxo)"
info "  in a pane  codex --remote unix:// --cd \"\$PWD\"   (alias: cx)"
