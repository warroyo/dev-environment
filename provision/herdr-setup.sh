#!/usr/bin/env bash
#
# Install herdr and make it the persistent-session path: the herdr server owns
# claude-main, and claude-tmux.service is stopped and disabled.
#
# server-bootstrap.sh calls this, so a normal provision run gets the whole
# thing. It stays runnable on its own for re-running just this part.
#
# tmux itself is NOT removed. It stays installed, ~/.tmux.conf stays managed,
# and tpm and its plugins stay where they are — tmux is still there for ad-hoc
# use and as the escape hatch if herdr disappoints. What changes is only which
# one holds the always-on Claude Code session.
#
# `./provision/herdr-setup.sh --uninstall` reverses it: herdr goes away and
# claude-tmux.service is re-enabled and started. That is the whole reason the
# tmux unit is disabled rather than deleted.
#
# Idempotent. Safe to re-run.
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/herdr.sh
# Shared with the two macOS bootstraps, and the reason the version is not
# written here: client and server negotiate a protocol version, so the pin has
# to be the same constant on every machine or attaching fails in a way that
# looks like anything but a version skew.
source "${SCRIPT_DIR}/lib/herdr.sh"

UNIT_PATH="/etc/systemd/system/herdr-server.service"
HERDR_BIN="$HOME/.local/bin/herdr"
UNINSTALL=0
CLAUDE_INTEGRATION=0
KEEP_TMUX_SERVICE=0

usage() {
  cat <<'EOF'
usage: provision/herdr-setup.sh [--with-claude-integration] [--uninstall]

  --with-claude-integration  also run `herdr integration install claude`, which
                             writes ~/.claude/hooks/herdr-agent-state.sh. OFF by
                             default because it modifies the GLOBAL Claude Code
                             config every session on this machine reads. See
                             the note below.
  --keep-tmux-service        leave claude-tmux.service enabled and running.
                             Both stacks then hold their own claude-main with
                             separate conversations, which is what the A/B
                             comparison did; not the normal state.
  --uninstall                remove herdr and hand the session back to
                             claude-tmux.service.

  HERDR_VERSION=vX.Y.Z       pin a different release (default: v0.8.0)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude-integration) CLAUDE_INTEGRATION=1; shift ;;
    --keep-tmux-service) KEEP_TMUX_SERVICE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'herdr-setup: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  log "Removing herdr-server.service"
  $SUDO systemctl disable --now herdr-server.service 2>/dev/null || true
  $SUDO rm -f "$UNIT_PATH"
  $SUDO systemctl daemon-reload
  # The unit's ExecStop already asked the server to stop, but a server started
  # by hand outside systemd would survive that, and it holds the sockets under
  # ~/.config/herdr that the next install would collide with.
  [ -x "$HERDR_BIN" ] && "$HERDR_BIN" server stop 2>/dev/null || true
  log "Removing $HERDR_BIN and ~/.config/herdr"
  rm -f "$HERDR_BIN"
  rm -rf "$HOME/.config/herdr"

  # Hand the session back. The tmux unit was disabled rather than deleted
  # precisely so this is one command and not a re-provision.
  log "Handing the persistent session back to claude-tmux.service"
  if [ -f /etc/systemd/system/claude-tmux.service ]; then
    $SUDO systemctl enable --now claude-tmux.service || \
      log "WARNING: could not start claude-tmux.service — check 'journalctl -u claude-tmux'."
    systemctl is-active claude-tmux.service || true
  else
    log "NOTE: claude-tmux.service does not exist. Re-run provision/server-bootstrap.sh"
    log "      to recreate it, or attach with 'tmux new-session -A -s claude-main'."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
log "Installing herdr ${HERDR_VERSION}"
# Downloading the pinned release binary rather than piping herdr.dev/install.sh
# into a shell: this is the always-on box, the pin makes a re-run reproducible,
# and ensure_herdr verifies the published sha256 before anything executes.
ensure_herdr

# A server started by hand (or by an earlier run) owns the socket the unit is
# about to bind, and herdr refuses to start a second one — "error: herdr server
# is already running". Stop it so systemd owns the only instance from here on.
if "$HERDR_BIN" status server 2>/dev/null | grep -q 'status: running'; then
  log "Stopping the herdr server that is already running, so systemd can own it"
  "$HERDR_BIN" server stop || true
  sleep 2
fi

# ---------------------------------------------------------------------------
CLAUDE_WORKDIR="${CLAUDE_WORKDIR:-$HOME/workspace}"
mkdir -p "$CLAUDE_WORKDIR"

if [ ! -x "$HOME/.local/bin/herdr-main-workspace" ]; then
  log "WARNING: ~/.local/bin/herdr-main-workspace missing — run 'chezmoi apply' first."
  log "         The server will start, but nothing will create the claude-main workspace."
fi

log "Writing herdr-server systemd service"
cat <<EOF | $SUDO tee "$UNIT_PATH" >/dev/null
# Managed by dev-environment/provision/herdr-setup.sh — do not edit by hand.
#
# The herdr counterpart to claude-tmux.service. Both may be enabled at once;
# they share nothing but the machine.
[Unit]
Description=herdr server (parallel A/B against claude-tmux.service)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
# Type=exec, not forking: \`herdr server\` runs in the foreground and IS the
# server, so systemd can supervise the real process instead of a launcher. This
# is also why there is no RemainAfterExit and no is-active caveat here — unlike
# claude-tmux.service, where the tmux client exits and leaves systemd reporting
# health it cannot actually see.
Type=exec
User=${USER}
WorkingDirectory=${CLAUDE_WORKDIR}
Environment=HOME=${HOME}
# Same PATH as claude-tmux.service and for the same reason: systemd's default
# excludes ~/.local/bin and the npm global bin dir, so without it the agents
# started inside herdr cannot find claude, and kubectl sees no krew plugins.
#
# The other half of why this list is explicit: the herdr server hands its own
# environment to every pane it spawns, so whatever launched the server ends up
# inside every agent. Start it by hand from inside a Claude Code session and
# each pane inherits that session's CLAUDE_CODE_* markers — including
# CLAUDE_CODE_CHILD_SESSION, which makes the nested claude announce
# "Transcript saving is off", and CLAUDE_CODE_MESSAGING_SOCKET, which points
# it at the parent session's socket. systemd starts from a clean slate plus
# exactly these lines, so the unit does not have that problem. A hand-started
# server does; \`env -i\` with this same set is the workaround if you ever need
# to run one outside systemd.
Environment=PATH=${HOME}/.local/bin:${HOME}/.krew/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${HERDR_BIN} server
# The server owns terminals but does not create any. herdr-main-workspace is
# the second half of what claude-tmux.service does in one line — it makes the
# claude-main workspace and starts claude in it, over the socket API, once the
# server is listening. It exits non-zero if the server never came up, which is
# what makes a broken start visible as a failed unit.
ExecStartPost=${HOME}/.local/bin/herdr-main-workspace
# Leading '-' so a failing stop is not treated as a unit failure. On any stop
# or restart systemd SIGTERMs the main process first, so by the time this runs
# the server is usually already gone and \`server stop\` exits 1 against a socket
# that no longer exists. Without the dash that marks the unit failed, and with
# Restart=always the result is a restart loop that looks like herdr crashing.
ExecStop=-${HERDR_BIN} server stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable herdr-server.service
# reset-failed before starting: an earlier bad unit (or a version of this file
# whose ExecStop failed on every stop) can leave a restart counter high enough
# that systemd refuses to start it again, and the resulting error names a rate
# limit rather than the thing that actually broke.
$SUDO systemctl reset-failed herdr-server.service 2>/dev/null || true
$SUDO systemctl restart herdr-server.service || \
  log "WARNING: herdr-server.service failed to start — check 'journalctl -u herdr-server'."

# ---------------------------------------------------------------------------
# Hand the persistent session over. This happens AFTER herdr is confirmed up,
# so a failed herdr install never leaves the machine with no session at all.
if [ "$KEEP_TMUX_SERVICE" -eq 1 ]; then
  log "Leaving claude-tmux.service alone (--keep-tmux-service)"
  log "Both stacks now hold a claude-main with separate conversations."
elif systemctl list-unit-files claude-tmux.service >/dev/null 2>&1 &&
     [ -f /etc/systemd/system/claude-tmux.service ]; then
  if systemctl is-enabled --quiet claude-tmux.service 2>/dev/null ||
     systemctl is-active --quiet claude-tmux.service 2>/dev/null; then
    log "Stopping and disabling claude-tmux.service — herdr owns the session now"
    # Disabled, not deleted, and the tmux session it started is left to die
    # with it rather than being killed separately: --uninstall re-enables this
    # unit, and that is only a real escape hatch if the unit still exists.
    $SUDO systemctl disable --now claude-tmux.service || \
      log "WARNING: could not disable claude-tmux.service — check 'systemctl status claude-tmux'."
  else
    log "claude-tmux.service already disabled"
  fi
fi

# ---------------------------------------------------------------------------
if [ "$CLAUDE_INTEGRATION" -eq 1 ]; then
  log "Installing the herdr Claude Code integration"
  # This writes ~/.claude/hooks/herdr-agent-state.sh and wires it into the
  # global Claude Code config. Two consequences worth being deliberate about:
  #
  #   1. It is GLOBAL. Every Claude Code session on this box reads that config,
  #      including any still started under tmux by hand. It is left opt-in for
  #      that reason alone — not because it is a bad idea. On a herdr-primary
  #      setup it is the recommended state.
  #   2. Without it, herdr infers agent state from terminal titles and screen
  #      contents, and a server restart relaunches claude as a FRESH session —
  #      the process comes back on its own within a few seconds, the
  #      conversation does not. With it, state comes from Claude Code's own
  #      lifecycle hooks and session.resume_agents_on_restore can restore the
  #      conversation itself, which is the part tmux-continuum has no answer
  #      for either.
  "$HERDR_BIN" integration install claude
  "$HERDR_BIN" server reload-config || true
else
  log "Skipping the Claude Code integration (--with-claude-integration to enable)."
  log "Recommended now that herdr owns the session: without it, agent state is"
  log "inferred from the screen, and a server restart brings claude back as a"
  log "fresh session instead of resuming the conversation — which is the job"
  log "tmux-continuum used to do here."
fi

# ---------------------------------------------------------------------------
log "Status"
printf '  herdr-server.service: %s\n' "$(systemctl is-active herdr-server.service 2>/dev/null || echo inactive)"
printf '  claude-tmux.service:  %s\n' "$(systemctl is-active claude-tmux.service 2>/dev/null || echo inactive)"
"$HERDR_BIN" workspace list 2>/dev/null || true
cat <<EOF

Attach from a client with:   claude-attach          (local herdr client over ssh)
                             claude-attach --mosh   (herdr client on the server)
                             claude-attach --tmux   (escape hatch: a plain tmux session)
Hand the session back with:  ./provision/herdr-setup.sh --uninstall
EOF
