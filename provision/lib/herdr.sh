#!/usr/bin/env bash
# herdr helpers, shared by all three bootstrap scripts.
#
#   ensure_herdr           installs the pinned binary. Every machine.
#   install_herdr_service  the server's systemd unit, the Claude Code
#                          integration, and the handover from tmux.
#
# The version lives HERE and nowhere else on purpose. A herdr client and server
# negotiate a protocol version (0.8.0 speaks protocol 19), and a mismatch
# between the Mac and the server is the first thing that breaks and the last
# thing you would think to check. One constant, used by every machine's
# bootstrap, means they cannot drift apart by accident.
#
# Not installed via Homebrew even on macOS: there is no official formula, the
# release binaries are what herdr.dev's own installer fetches, and going
# straight to them is what lets this pin a version and verify a checksum.

HERDR_VERSION="${HERDR_VERSION:-v0.8.0}"

# herdr.dev publishes a manifest with per-platform URLs AND sha256 sums. Both
# the client and the update machinery inside herdr itself read it.
HERDR_MANIFEST_URL="${HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}"

# ensure_herdr [version]
#
# Installs herdr to ~/.local/bin/herdr unless the pinned version is already
# there. Returns non-zero if the download cannot be verified.
ensure_herdr() {
  local want="${1:-$HERDR_VERSION}"
  local bare="${want#v}"
  local dest="$HOME/.local/bin/herdr"
  local os arch key url want_sha got_sha tmp

  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) echo "  ERROR: herdr: unsupported OS $(uname -s)" >&2; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *) echo "  ERROR: herdr: unsupported architecture $(uname -m)" >&2; return 1 ;;
  esac
  key="${os}-${arch}"

  if [ -x "$dest" ] && [ "$("$dest" --version 2>/dev/null)" = "herdr ${bare}" ]; then
    echo "  herdr ${bare} already installed"
    return 0
  fi

  # Ask the manifest for the URL rather than hard-coding a GitHub path: the
  # project has already moved organizations once (herdrdev/herdr), and the
  # manifest is what herdr's own updater follows.
  local meta
  meta="$(curl -fsSL "$HERDR_MANIFEST_URL" | python3 -c '
import json, sys
want, key = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
# The top level describes the CURRENT release; older ones live under releases.
rel = d if d.get("version") == want else d.get("releases", {}).get(want)
if not rel:
    sys.exit(3)
url = rel.get("assets", {}).get(key)
if not url:
    sys.exit(4)
# Only the current release carries checksums in this manifest; an older pin
# gets an empty second field and is reported as unverified below.
print(url)
print((rel.get("sha256") or {}).get(key, ""))
' "$bare" "$key")" || {
    echo "  ERROR: herdr: no ${key} build published for ${bare}" >&2
    return 1
  }

  url="$(printf '%s\n' "$meta" | sed -n 1p)"
  want_sha="$(printf '%s\n' "$meta" | sed -n 2p)"

  echo "  installing herdr ${bare} (${key})"
  tmp="$(mktemp)"
  # No trap here: this is sourced into scripts that set their own, and an EXIT
  # trap installed by a helper would silently replace the caller's.
  if ! curl -fsSL -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "  ERROR: herdr: download failed: $url" >&2
    return 1
  fi

  if [ -n "$want_sha" ]; then
    # macOS ships shasum, Linux ships sha256sum, and this helper runs on both.
    if command -v sha256sum >/dev/null 2>&1; then
      got_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
    else
      got_sha="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
    fi
    if [ "$got_sha" != "$want_sha" ]; then
      rm -f "$tmp"
      echo "  ERROR: herdr: checksum mismatch for ${key}" >&2
      echo "         expected ${want_sha}" >&2
      echo "         got      ${got_sha}" >&2
      return 1
    fi
    echo "  checksum verified"
  else
    # Pinning an older version is legitimate, but say plainly that the download
    # was not verified rather than implying it was.
    echo "  NOTE: herdr.dev publishes no checksum for ${bare} — download NOT verified"
  fi

  chmod +x "$tmp"
  # Run it before installing it: a truncated download or a wrong-arch binary is
  # the realistic failure, and finding out now beats finding out at attach time.
  if ! "$tmp" --version >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "  ERROR: herdr: downloaded binary does not run" >&2
    return 1
  fi

  mkdir -p "$HOME/.local/bin"
  install -m 755 "$tmp" "$dest"
  rm -f "$tmp"
  echo "  installed $("$dest" --version) to $dest"
}

# install_herdr_service
#
# The server half: the systemd unit that holds the persistent Claude Code
# session, plus the Claude Code integration that makes agent state come from
# Claude Code's own lifecycle hooks. Called by server-bootstrap.sh.
#
# Expects the caller to have defined `log` and `$SUDO`, as both bootstrap
# scripts do, and to have run the chezmoi apply first — this needs
# ~/.local/bin/herdr-main-workspace to exist.
#
# Idempotent. Honours $CLAUDE_WORKDIR (default ~/workspace).
install_herdr_service() {
  local unit_path="/etc/systemd/system/herdr-server.service"
  local herdr_bin="$HOME/.local/bin/herdr"
  local workdir="${CLAUDE_WORKDIR:-$HOME/workspace}"

  ensure_herdr || return 1
  mkdir -p "$workdir"

  # A server started by hand (or by an earlier run) owns the socket the unit is
  # about to bind, and herdr refuses to start a second one — "error: herdr
  # server is already running". Stop it so systemd owns the only instance.
  if "$herdr_bin" status server 2>/dev/null | grep -q 'status: running'; then
    log "Stopping the herdr server that is already running, so systemd can own it"
    "$herdr_bin" server stop || true
    sleep 2
  fi

  if [ ! -x "$HOME/.local/bin/herdr-main-workspace" ]; then
    log "WARNING: ~/.local/bin/herdr-main-workspace missing — run 'chezmoi apply' first."
    log "         The server will start, but nothing will create the claude-main workspace."
  fi

  log "Writing herdr-server systemd service"
  cat <<EOF | $SUDO tee "$unit_path" >/dev/null
# Managed by dev-environment/provision/lib/herdr.sh — do not edit by hand.
[Unit]
Description=herdr server (persistent Claude Code session)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
# Type=exec, not forking: \`herdr server\` runs in the foreground and IS the
# server, so systemd supervises the real process instead of a launcher. That is
# why \`systemctl is-active\` is meaningful here, unlike the old
# claude-tmux.service where the tmux client exited and left systemd reporting
# health it could not actually see.
Type=exec
User=${USER}
WorkingDirectory=${workdir}
Environment=HOME=${HOME}
# systemd's default PATH excludes ~/.local/bin and the npm global bin dir, so
# without this the agents started inside herdr cannot find claude, and kubectl
# sees no krew plugins.
#
# The other half of why this list is explicit: the herdr server hands its own
# environment to every pane it spawns, so whatever launched the server ends up
# inside every agent. Start it by hand from inside a Claude Code session and
# each pane inherits that session's CLAUDE_CODE_* markers — including
# CLAUDE_CODE_CHILD_SESSION, which makes the nested claude announce
# "Transcript saving is off", and CLAUDE_CODE_MESSAGING_SOCKET, which points it
# at the parent session's socket. systemd starts from a clean slate plus
# exactly these lines, so the unit does not have that problem. A hand-started
# server does; \`env -i\` with this same set is the workaround if you ever need
# to run one outside systemd.
Environment=PATH=${HOME}/.local/bin:${HOME}/.krew/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${herdr_bin} server
# The server owns terminals but creates none. herdr-main-workspace is the second
# half of what claude-tmux.service used to do in one line — it makes the
# claude-main workspace and starts claude in it, over the socket API, once the
# server is listening. It exits non-zero if the server never came up, which is
# what makes a broken start visible as a failed unit.
ExecStartPost=${HOME}/.local/bin/herdr-main-workspace
# Leading '-' so a failing stop is not a unit failure. On any stop or restart
# systemd SIGTERMs the main process first, so by the time this runs the server
# is usually already gone and \`server stop\` exits 1 against a socket that no
# longer exists. Without the dash that marks the unit failed, and with
# Restart=always the result is a restart loop that looks like herdr crashing.
ExecStop=-${herdr_bin} server stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable herdr-server.service
  # reset-failed before starting: an earlier bad unit can leave a restart
  # counter high enough that systemd refuses to start it again, and the error
  # then names a rate limit rather than the thing that actually broke.
  $SUDO systemctl reset-failed herdr-server.service 2>/dev/null || true
  $SUDO systemctl restart herdr-server.service || \
    log "WARNING: herdr-server.service failed to start — check 'journalctl -u herdr-server'."

  # -------------------------------------------------------------------------
  # Agent state from Claude Code's own lifecycle hooks rather than from reading
  # the screen. This is also what lets session.resume_agents_on_restore put the
  # CONVERSATION back after a server restart, not just the process — the job
  # tmux-continuum used to do here.
  #
  # It writes ~/.claude/hooks/herdr-agent-state.sh and a SessionStart hook into
  # ~/.claude/settings.json, which is global: every Claude Code session on this
  # box reads it. That is worth knowing, not worth avoiding, now that herdr owns
  # the session. herdr manages the hook file itself and overwrites it on
  # update — custom hooks go beside it, never inside it.
  log "Installing the herdr Claude Code integration"
  "$herdr_bin" integration install claude || \
    log "WARNING: could not install the Claude Code integration — agent state will fall back to reading the screen, and conversations will not resume after a restart."
  "$herdr_bin" server reload-config >/dev/null 2>&1 || true

  # -------------------------------------------------------------------------
  # Hand the persistent session over, AFTER herdr is confirmed up, so a failed
  # herdr install never leaves the machine with no session at all.
  #
  # Disabled, not deleted: it is the way back. To return to tmux, disable this
  # unit and re-enable that one —
  #   sudo systemctl disable --now herdr-server.service
  #   sudo systemctl enable  --now claude-tmux.service
  # which is why claude-session still ships even though nothing on the herdr
  # path calls it.
  if [ -f /etc/systemd/system/claude-tmux.service ] &&
     systemctl is-enabled --quiet claude-tmux.service 2>/dev/null; then
    log "Disabling claude-tmux.service — herdr owns the session now"
    $SUDO systemctl disable --now claude-tmux.service || \
      log "WARNING: could not disable claude-tmux.service — check 'systemctl status claude-tmux'."
  fi
}
