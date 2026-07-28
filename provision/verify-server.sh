#!/usr/bin/env bash
#
# Read-only health check for the Ubuntu server. Changes nothing — safe to run
# any time, and the right thing to run after a reboot or an OS upgrade.
#
# Exit status: 0 if every check passed, 1 if any FAILed. WARNs don't fail the
# run (they're "expected in some states", e.g. the second OpenVPN environment
# not being configured yet).
set -uo pipefail

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
section "Tooling"
for c in zsh tmux git docker kubectl chezmoi tailscale mosh-server rg fzf eza; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c present"; else bad "$c MISSING"; fi
done
# Ubuntu ships these under different binary names; server-bootstrap.sh
# symlinks them into ~/.local/bin under the names the aliases expect.
check_renamed() {
  if command -v "$1" >/dev/null 2>&1; then ok "$1 present (Ubuntu ships it as $2)"
  else warn "$1 not on PATH — expected a ~/.local/bin symlink to $2"; fi
}
check_renamed fd fdfind
check_renamed bat batcat
if command -v claude >/dev/null 2>&1; then
  ok "claude present ($(claude --version 2>/dev/null || echo '?'))"
else
  bad "claude MISSING — claude-tmux.service cannot work without it"
fi

# ---------------------------------------------------------------------------
section "Shell + dotfiles"
[ "$(getent passwd "$USER" | cut -d: -f7)" = "$(command -v zsh)" ] \
  && ok "login shell is zsh" || bad "login shell is not zsh"
for f in .zshenv .zshrc .tmux.conf .gitconfig .gitconfig.local .ssh/config; do
  [ -f "$HOME/$f" ] && ok "~/$f present" || bad "~/$f MISSING — run chezmoi apply"
done
# Tier 1 must reach NON-interactive shells, or `ssh host <cmd>` can't find
# anything in ~/.local/bin. This is the bug .zshenv exists to prevent.
if zsh -c 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0;; *) exit 1;; esac' 2>/dev/null; then
  ok "~/.local/bin on PATH in a non-interactive shell"
else
  bad "~/.local/bin missing from non-interactive PATH — check ~/.zshenv"
fi
# Identity must resolve through the include chain, not be blank.
if [ -n "$(git config user.email 2>/dev/null)" ]; then
  ok "git identity resolves ($(git config user.email))"
else
  bad "git has no user.email — fill in ~/.gitconfig.local"
fi
# Existence alone doesn't prove chezmoi owns it (a pre-existing file counts
# as present), so ask chezmoi whether anything managed has drifted.
if command -v chezmoi >/dev/null 2>&1; then
  # Pass --source explicitly: chezmoi's configured sourceDir may be its
  # default (~/.local/share/chezmoi) rather than this repo's dotfiles/.
  VERIFY_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../dotfiles" && pwd)"
  if chezmoi verify --source="$VERIFY_SRC" >/dev/null 2>&1; then
    ok "all chezmoi-managed files match the source"
  else
    warn "chezmoi reports drift — run 'chezmoi diff' to see what differs"
  fi
fi
if [ -f "$HOME/.ssh/config" ]; then
  perms="$(stat -c %a "$HOME/.ssh/config")"
  [ "$perms" = "600" ] && ok ".ssh/config is 0600" \
    || bad ".ssh/config is 0$perms — OpenSSH rejects group/world-writable configs"
fi
for s in claude-attach claude-env; do
  [ -x "$HOME/.local/bin/$s" ] && ok "$s installed and executable" || bad "$s missing from ~/.local/bin"
done

# ---------------------------------------------------------------------------
section "Prompt + shell plugins"
if command -v starship >/dev/null 2>&1; then
  ok "starship present ($(starship --version 2>/dev/null | head -n1))"
  [ -f "$HOME/.config/starship.toml" ] && ok "starship.toml applied" \
    || warn "~/.config/starship.toml missing — starship will use its defaults"
else
  warn "starship not installed — zsh falls back to the plain built-in prompt"
fi
# Confirm the prompt is actually wired up, not just that the binary exists.
# A bare zsh prompt is "%m%# " (6 chars); starship's is far longer.
#
# setsid is load-bearing, and redirecting stdin is not enough on its own.
# `zsh -i` starts zle, and zle opens /dev/tty *directly* — so run from a
# terminal it grabs the tty and blocks even with all three fds redirected.
# `timeout` alone cannot rescue it either, because interactive shells ignore
# SIGTERM. setsid drops the controlling terminal so there is no /dev/tty to
# open; -k adds a SIGKILL backstop. Without this the substitution yields
# nothing and the branch below reports a bare prompt no matter how well
# starship is configured.
PROMPT_LEN="$(setsid timeout -k 2 10 zsh -i -c 'print -r -- ${#PROMPT}' </dev/null 2>/dev/null | tail -n1)"
if [ -z "${PROMPT_LEN:-}" ]; then
  bad "could not measure the interactive prompt — 'zsh -i' timed out or failed"
elif [ "$PROMPT_LEN" -gt 20 ] 2>/dev/null; then
  ok "interactive prompt is configured (length ${PROMPT_LEN})"
else
  bad "interactive prompt looks like zsh's bare default (length ${PROMPT_LEN}) —"
  bad "  check the starship init in ~/.config/shell/source/50_prompt.sh"
fi
for p in zsh-autosuggestions zsh-syntax-highlighting; do
  if [ -r "/usr/share/${p}/${p}.zsh" ] || [ -r "/usr/share/zsh/plugins/${p}/${p}.zsh" ]; then
    ok "$p installed"
  else
    warn "$p not installed — run 'sudo apt install $p' or re-run server-bootstrap.sh"
  fi
done

# ---------------------------------------------------------------------------
section "tmux plugins"
for p in tmux-resurrect tmux-continuum; do
  [ -d "$HOME/.tmux/plugins/$p" ] && ok "$p installed" \
    || bad "$p MISSING — session state will not survive a reboot"
done

# ---------------------------------------------------------------------------
section "Tailscale"
if tailscale status >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
  ok "tailnet up (${TS_IP})"
else
  bad "tailscale is not logged in — run 'sudo tailscale up'"
  TS_IP=""
fi

# ---------------------------------------------------------------------------
section "ssh bindings (must be LAN + Tailscale only, never WAN)"
LISTENERS="$(ss -tlnH '( sport = :22 )' 2>/dev/null | awk '{print $4}')"
if [ -z "$LISTENERS" ]; then
  bad "nothing is listening on :22"
else
  if echo "$LISTENERS" | grep -qE '^(0\.0\.0\.0|\*|\[::\]):22$'; then
    bad "WILDCARD bind present — ssh is listening on every interface incl. WAN:"
    echo "$LISTENERS" | sed 's/^/          /'
  else
    ok "no wildcard bind"
  fi
  # Every RFC1918 address on a physical interface should be bound, or that
  # path (e.g. the work laptop's OpenVPN-to-LAN) silently can't connect.
  while read -r ip; do
    [ -z "$ip" ] && continue
    if echo "$LISTENERS" | grep -q "^${ip}:22$"; then ok "bound on LAN ${ip}"
    else warn "LAN ${ip} is NOT bound — connections arriving there will be refused"; fi
  done < <(
    ip -o -4 addr show scope global 2>/dev/null \
      | awk '{split($4,a,"/"); print $2" "a[1]}' \
      | grep -vE '^(lo|docker|br-|veth|virbr|tailscale|tun|wg)' \
      | awk '{print $2}' \
      | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | sort -u
  )
  if [ -n "$TS_IP" ]; then
    echo "$LISTENERS" | grep -q "^${TS_IP}:22$" \
      && ok "bound on Tailscale ${TS_IP}" \
      || bad "Tailscale ${TS_IP} is NOT bound — the personal Air cannot connect"
  fi
fi
printf '        (reminder: confirm the UDM SE has no WAN port-forward to :22 — not checkable from here)\n'

# ---------------------------------------------------------------------------
section "Persistent Claude session"
systemctl is-enabled --quiet claude-tmux.service 2>/dev/null \
  && ok "claude-tmux.service enabled (starts on boot)" \
  || bad "claude-tmux.service NOT enabled — it will not come back after a reboot"
systemctl is-active --quiet claude-tmux.service 2>/dev/null \
  && ok "claude-tmux.service active" || bad "claude-tmux.service not active"
if tmux has-session -t claude-main 2>/dev/null; then
  ok "tmux session 'claude-main' exists"
  # Do NOT use #{pane_current_command} alone: the systemd unit runs
  # `claude; exec $SHELL -l` so the pane's own process is the wrapping shell
  # and claude is its CHILD. tmux reports the pane process, so that check
  # reports "no claude" while claude is running perfectly well.
  _claude_in_pane() {
    local pid="$1" child
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')" = "claude" ] && return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      [ "$(ps -o comm= -p "$child" 2>/dev/null | tr -d ' ')" = "claude" ] && return 0
    done
    return 1
  }
  CLAUDE_FOUND=0
  for p in $(tmux list-panes -t claude-main -F '#{pane_pid}' 2>/dev/null); do
    _claude_in_pane "$p" && { CLAUDE_FOUND=1; break; }
  done

  if [ "$CLAUDE_FOUND" -eq 1 ]; then
    ok "claude is running inside claude-main"
  else
    warn "claude-main exists but no 'claude' process in it"
    # Most common cause: claude hit the interactive trust prompt for its
    # working directory, got no answer, and exited into the shell fallback.
    PANE_DIR="$(tmux display-message -p -t claude-main '#{pane_current_path}' 2>/dev/null)"
    if [ -n "${PANE_DIR:-}" ]; then
      printf '        session cwd: %s\n' "$PANE_DIR"
      if [ -f "$HOME/.claude.json" ] && command -v python3 >/dev/null 2>&1; then
        python3 - "$HOME/.claude.json" "$PANE_DIR" <<'PYEOF' 2>/dev/null
import json, sys
cfg, d = sys.argv[1], sys.argv[2]
p = json.load(open(cfg)).get("projects", {}).get(d, {})
t = p.get("hasTrustDialogAccepted")
if t is True:
    print("        that directory IS trusted — check 'tmux capture-pane -p -t claude-main' for the real error")
else:
    print(f"        that directory is NOT trusted by Claude Code, which is very likely why it exited.")
    print(f"        fix: re-run server-bootstrap.sh, or run 'claude' there once and accept the prompt")
PYEOF
      fi
    fi
  fi
else
  bad "tmux session 'claude-main' does not exist"
fi

# ---------------------------------------------------------------------------
section "Second OpenVPN environment (on-demand)"
OVPN_CONF="/etc/openvpn/client/client-env.conf"
if [ -f "$OVPN_CONF" ]; then
  ok "client-env.conf present"

  # The key is embedded in this file, so anything world-readable is a finding.
  perms="$(stat -c '%a %U' "$OVPN_CONF" 2>/dev/null || echo '? ?')"
  case "$perms" in
    "600 root") ok "client-env.conf is 600 root-owned" ;;
    *) bad "client-env.conf should be 600 root-owned, is: $perms" ;;
  esac

  # Not being connected is the normal resting state: the identity is shared
  # with other machines, so the tunnel is on-demand and off by default.
  if systemctl is-enabled --quiet openvpn-client@client-env 2>/dev/null; then
    bad "openvpn-client@client-env is enabled at boot — it must stay on-demand,"
    bad "  because the VPN identity is shared with other machines"
  else
    ok "openvpn-client@client-env not enabled at boot (correct: shared identity)"
  fi

  # The drop-in is the real signal: server-bootstrap.sh only writes it once it
  # has actually located update-systemd-resolved, whose path varies by
  # packaging, so testing for the script here would just re-guess that path.
  OVPN_DNS_DROPIN="/etc/systemd/system/openvpn-client@client-env.service.d/dns.conf"
  if [ -f "$OVPN_DNS_DROPIN" ]; then
    ok "pushed DNS is wired into systemd-resolved"
  else
    bad "the tunnel's pushed DNS is not wired into systemd-resolved — internal"
    bad "  names will not resolve while connected; re-run server-bootstrap.sh"
  fi

  if ip link show tun0 >/dev/null 2>&1; then
    ok "tun0 up ($(ip -4 -brief addr show tun0 | awk '{print $3}')) — currently connected"
    # A tunnel with no DNS scope is the failure mode that looks perfectly
    # healthy: routes fine, every internal name fails.
    if resolvectl status tun0 2>/dev/null | grep -q 'DNS Servers:'; then
      ok "tun0 has DNS: $(resolvectl status tun0 2>/dev/null | sed -n 's/.*DNS Servers: *//p' | head -n1)"
    else
      bad "tun0 has no DNS servers (resolvectl status tun0 shows no scope) —"
      bad "  internal names will not resolve; reconnect with 'client-vpn down && client-vpn up'"
    fi
  else
    ok "tun0 absent — not connected (normal; 'client-vpn up' to connect)"
  fi

  # docker0 must not sit in the range the tunnel pushes (172.17.0.0/24), or
  # the tunnel captures exactly the addresses the bridge hands out.
  if ip -4 -brief addr show docker0 2>/dev/null | grep -q '172\.17\.0\.'; then
    bad "docker0 is on 172.17.0.x, which the client VPN's pushed 172.17.0.0/24"
    bad "  will capture — set a \"bip\" in /etc/docker/daemon.json"
  else
    ok "docker0 is clear of the pushed 172.17.0.0/24"
  fi
else
  warn "no client-env.conf yet — the second environment is not configured (expected if unused)"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mSummary:\033[0m %d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
