#!/usr/bin/env bash
# Codex CLI helpers for the server bootstrap.
#
#   ensure_codex_cli             installs the standalone (installer-managed) CLI
#   install_codex_bwrap_apparmor lets Codex's sandbox open user namespaces
#   install_codex_daemon_service starts the app-server daemon at boot, with
#                                remote control on for the ChatGPT app
#
# Expects the caller to have defined `log` and `$SUDO`, same as lib/herdr.sh.
#
# WHY STANDALONE AND NOT npm
#
# This used to be `npm install -g @openai/codex`, which was the tidy choice
# while Codex was only ever run by hand: npm and ~/.npm-global were already set
# up, and its bin dir was already on PATH everywhere. But the remote-control
# daemon — the thing that makes a session reachable from the ChatGPT app —
# refuses to start from an npm install:
#
#   Error: managed standalone Codex install not found at
#   ~/.codex/packages/standalone/current/codex
#
# The daemon starts and self-updates app-server from that fixed path, so it has
# to be the installer-managed copy. Same CLI, same release stream, same
# ~/.codex (auth included) — only the install mechanism differs.

CODEX_INSTALL_URL="${CODEX_INSTALL_URL:-https://chatgpt.com/codex/install.sh}"
CODEX_STANDALONE_BIN="${CODEX_STANDALONE_BIN:-$HOME/.codex/packages/standalone/current/codex}"
CODEX_BIN="${CODEX_BIN:-$HOME/.local/bin/codex}"

# ensure_codex_cli
#
# Installs the standalone Codex CLI unless it is already there. Returns
# non-zero if the install fails; the caller decides whether that is fatal.
ensure_codex_cli() {
  if [ -x "$CODEX_STANDALONE_BIN" ]; then
    log "  Codex CLI already installed ($("$CODEX_BIN" --version 2>/dev/null || echo 'version unknown'))"
    return 0
  fi

  # Remove an npm-managed Codex FIRST, for two reasons. Two copies on PATH mean
  # PATH order silently decides which one runs, and the installer reacts to
  # finding one by appending a PATH block to ~/.zshrc — which is chezmoi's
  # file here, so that edit is drift that the next `chezmoi apply` reverts.
  # With no conflicting install the installer leaves the shell config alone,
  # because ~/.local/bin is already on PATH (dot_zshenv).
  if [ -e "$HOME/.npm-global/bin/codex" ]; then
    log "  removing the npm-managed Codex (the daemon cannot use it)"
    npm uninstall -g @openai/codex >/dev/null 2>&1 || \
      log "  WARNING: 'npm uninstall -g @openai/codex' failed — remove it by hand,"
  fi

  # CODEX_NON_INTERACTIVE is not optional. The installer ends by asking "Start
  # Codex now?" and, given a tty, would launch the TUI in the middle of a
  # bootstrap run and sit there. With it set, every prompt answers "no".
  #
  # PATH is exported explicitly so the installer sees ~/.local/bin already on
  # it; that is the check that decides whether it edits a shell profile.
  if PATH="$HOME/.local/bin:$PATH" CODEX_NON_INTERACTIVE=1 \
       sh -c "curl -fsSL '$CODEX_INSTALL_URL' | sh"; then
    log "  Codex CLI installed"
    return 0
  fi

  log "  WARNING: automatic Codex CLI install failed. Install it manually with"
  log "           'curl -fsSL ${CODEX_INSTALL_URL} | sh', then re-run this script."
  return 1
}

# install_codex_bwrap_apparmor
#
# Codex sandboxes every command it runs through bubblewrap, which needs to
# create user namespaces. Ubuntu 24.04 forbids that to unconfined binaries
# (kernel.apparmor_restrict_unprivileged_userns=1), and the failure names
# neither AppArmor nor Codex:
#
#   bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted
#
# so name the binary in a profile that grants `userns`.
#
# TWO binaries, because Codex prefers a system bwrap on PATH and only falls
# back to its own ("no system bwrap was found on PATH and no bundled
# codex-resources/bwrap binary was found next to the Codex executable"). On
# this box /usr/bin/bwrap exists as a dependency of the `code` package, so the
# system one is what actually runs and a profile covering only the bundled copy
# tests clean while Codex still fails. There is no env var to force the bundled
# path — CODEX_BWRAP_SHA256 verifies one, it does not select one.
#
# Scope of what this grants: a program that invokes bwrap may create user
# namespaces. That is narrower than it sounds — bwrap exists to let unprivileged
# programs sandbox themselves, so anything able to call it could already do the
# sandboxing this permits, and every other unconfined binary stays restricted.
# The alternative that does NOT need this (symlinking ~/.local/bin/bwrap to
# Codex's bundled build so it wins the PATH lookup) silently replaces the bwrap
# that VS Code's own sandbox uses, which is a stranger thing to leave behind.
# What is deliberately not done here is turning the sysctl off, which would drop
# the restriction for every binary on the machine.
install_codex_bwrap_apparmor() {
  local profile=/etc/apparmor.d/codex-bwrap tmp

  # Nothing to do where AppArmor does not gate user namespaces (an older
  # Ubuntu, a container, a non-AppArmor distro).
  if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" != "1" ]; then
    log "  unprivileged user namespaces are unrestricted — no AppArmor profile needed"
    return 0
  fi
  command -v apparmor_parser >/dev/null 2>&1 || {
    log "  WARNING: apparmor_parser missing — Codex's sandbox will fail to start commands"
    return 0; }

  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
# Managed by dev-environment/provision/lib/codex.sh — do not edit by hand.
#
# Ubuntu 24.04 restricts unprivileged user namespaces, and Codex's Linux
# sandbox is a bundled bubblewrap that needs them. Without a profile naming it,
# every sandboxed command dies with:
#
#   bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted
#
# Two profiles, because Codex runs whichever bwrap it finds first: a system one
# on PATH if there is one (Ubuntu has /usr/bin/bwrap as a dependency of the
# `code` package), otherwise the copy bundled next to the Codex binary.
#
# The bundled path globs over the release directory rather than following
# `current`, because the standalone installer gives each version its own
# directory and flips that symlink — AppArmor matches the RESOLVED path, so a
# profile pinned to `current` would stop applying at the next Codex update. The
# `/home/*` glob covers whichever user account this is.
#
# If a future Ubuntu ships its own profile attached to /usr/bin/bwrap,
# apparmor_parser will refuse this one as a conflict rather than silently
# picking a winner — at which point the system half here can be deleted.
abi <abi/4.0>,
include <tunables/global>

profile codex-bwrap-system /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/codex-bwrap>
}

profile codex-bwrap-bundled /home/*/.codex/packages/standalone/releases/*/codex-resources/bwrap flags=(unconfined) {
  userns,
  include if exists <local/codex-bwrap>
}
EOF

  if $SUDO cmp -s "$tmp" "$profile" 2>/dev/null; then
    log "  AppArmor profile for Codex's bubblewrap already current"
    rm -f "$tmp"
    return 0
  fi
  $SUDO cp "$tmp" "$profile"
  $SUDO chmod 644 "$profile"
  rm -f "$tmp"
  if $SUDO apparmor_parser -r "$profile"; then
    log "  AppArmor profile for Codex's bubblewrap loaded"
  else
    log "  WARNING: apparmor_parser rejected ${profile} — Codex's sandbox will not work"
  fi
}

# install_codex_daemon_service
#
# The app-server daemon is what the ChatGPT app talks to, and what every local
# `codex` TUI registers its session with — one daemon, one session list, phone
# and laptop looking at the same thing.
#
# `codex app-server daemon bootstrap --remote-control` is Codex's own "durable
# management for SSH-driven use": it starts the daemon, records
# remoteControlEnabled in ~/.codex/app-server-daemon/settings.json so future
# starts keep it, and leaves an updater process alongside. What it does NOT do
# is survive a reboot — it is a bare pid, not a service — hence the unit.
#
# Type=oneshot + RemainAfterExit, not Type=simple: `daemon start` returns as
# soon as the daemon is up, and the daemon itself detaches. systemd therefore
# does not supervise the process — Codex's own pid file and updater loop do.
# The unit's job is only "run this once at boot".
install_codex_daemon_service() {
  local unit_path=/etc/systemd/system/codex-app-server.service tmp

  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Managed by dev-environment/provision/lib/codex.sh — do not edit by hand.
[Unit]
Description=Codex app-server daemon (remote control for the ChatGPT app)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${USER}
WorkingDirectory=${HOME}
Environment=HOME=${HOME}
# Same PATH reasoning as herdr-server.service and claude-telegram-bot.service:
# systemd's default omits ~/.local/bin, where the codex shim lives.
Environment=PATH=${HOME}/.local/bin:${HOME}/.krew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${HOME}/.local/bin/codex app-server daemon start
ExecStop=${HOME}/.local/bin/codex app-server daemon stop

[Install]
WantedBy=multi-user.target
EOF

  if $SUDO cmp -s "$tmp" "$unit_path" 2>/dev/null; then
    log "  codex-app-server.service already current"
  else
    $SUDO cp "$tmp" "$unit_path"
    $SUDO chmod 644 "$unit_path"
    $SUDO systemctl daemon-reload
  fi
  rm -f "$tmp"

  $SUDO systemctl enable codex-app-server.service >/dev/null 2>&1 || true

  # Remote control is a per-machine ENROLLMENT, not just a flag: the daemon
  # registers with the ChatGPT backend, which rejects accounts without MFA
  # ("HTTP 403 ... Multi-factor authentication required"). So this is allowed
  # to fail without failing the bootstrap — the daemon still runs and local
  # sessions still work; only the phone half waits for `codex login`.
  if "$CODEX_BIN" app-server daemon bootstrap --remote-control >/dev/null 2>&1; then
    log "  app-server daemon running with remote control enabled"
    log "  pair a phone with: codex remote-control pair"
  else
    $SUDO systemctl start codex-app-server.service >/dev/null 2>&1 || true
    log "  WARNING: could not enable remote control. Usually one of:"
    log "           - not logged in yet          -> codex login"
    log "           - the account has no MFA     -> enable 2FA, then codex login again"
    log "           Check with: codex remote-control start"
  fi
}
