#!/usr/bin/env bash
#
# Install herdr and run it as a SECOND, parallel persistent-session path
# alongside claude-tmux.service, so the two can be A/B'd on the same server
# without either being torn out.
#
# Deliberately standalone rather than folded into server-bootstrap.sh: this is
# an evaluation, and an evaluation you cannot cleanly reverse is not one.
# `./provision/herdr-setup.sh --uninstall` removes everything this adds.
#
# What it does NOT touch:
#   claude-tmux.service, claude-telegram-bot.service, ~/.tmux.conf, tpm and its
#   plugins, ~/.ssh/config, or ~/.claude (see --with-claude-integration below).
#
# Both stacks running at once costs ~16 MB RSS for the herdr server. They are
# independent: the tmux claude-main session and the herdr claude-main workspace
# are separate Claude Code processes with separate conversations.
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

usage() {
  cat <<'EOF'
usage: provision/herdr-setup.sh [--with-claude-integration] [--uninstall]

  --with-claude-integration  also run `herdr integration install claude`, which
                             writes ~/.claude/hooks/herdr-agent-state.sh. OFF by
                             default because it modifies the GLOBAL Claude Code
                             config that every session on this machine reads,
                             including the tmux ones. See the note below.
  --uninstall                stop and remove the unit, the binary and
                             ~/.config/herdr. Leaves the tmux path untouched.

  HERDR_VERSION=vX.Y.Z       pin a different release (default: v0.8.0)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude-integration) CLAUDE_INTEGRATION=1; shift ;;
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
  log "Done. claude-tmux.service was not touched:"
  systemctl is-active claude-tmux.service || true
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
Environment=PATH=${HOME}/.local/bin:${HOME}/.krew/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${HERDR_BIN} server
# The server owns terminals but does not create any. herdr-main-workspace is
# the second half of what claude-tmux.service does in one line — it makes the
# claude-main workspace and starts claude in it, over the socket API, once the
# server is listening. It exits non-zero if the server never came up, which is
# what makes a broken start visible as a failed unit.
ExecStartPost=${HOME}/.local/bin/herdr-main-workspace
ExecStop=${HERDR_BIN} server stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable herdr-server.service
$SUDO systemctl restart herdr-server.service || \
  log "WARNING: herdr-server.service failed to start — check 'journalctl -u herdr-server'."

# ---------------------------------------------------------------------------
if [ "$CLAUDE_INTEGRATION" -eq 1 ]; then
  log "Installing the herdr Claude Code integration"
  # This writes ~/.claude/hooks/herdr-agent-state.sh and wires it into the
  # global Claude Code config. Two consequences worth being deliberate about:
  #
  #   1. It is GLOBAL. Every Claude Code session on this box reads that config,
  #      including the ones running under tmux, which are supposed to be the
  #      control arm of this comparison.
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
  log "Without it, agent state is inferred from the screen, and a server restart"
  log "brings claude back as a fresh session rather than resuming the conversation."
fi

# ---------------------------------------------------------------------------
log "Status"
systemctl is-active herdr-server.service && echo "  herdr-server.service: active"
systemctl is-active claude-tmux.service  && echo "  claude-tmux.service:  active (untouched)"
"$HERDR_BIN" workspace list 2>/dev/null || true
cat <<EOF

Attach from a client with:   claude-attach-herdr        (local client over ssh)
                             claude-attach-herdr --mosh (client on the server)
The tmux path is unchanged:  claude-attach
Reverse all of this with:    ./provision/herdr-setup.sh --uninstall
EOF
