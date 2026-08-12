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

# Refuse to run as root. Almost everything here is a question about the
# invoking USER's environment — their dotfiles, their PATH, their tmux session,
# their git identity. Under sudo, HOME becomes /root and secure_path drops
# ~/.local/bin, so the run turns into a wall of failures describing root's
# missing setup rather than anything actually wrong. The two checks that
# genuinely need root escalate on their own, further down.
if [ "$(id -u)" -eq 0 ]; then
  printf 'Run this as your normal user, not with sudo — it checks YOUR shell,\n' >&2
  printf 'dotfiles and PATH, and root has none of them. The couple of checks\n' >&2
  printf 'that need root escalate by themselves.\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
section "Tooling"
for c in zsh tmux git docker kubectl terraform chezmoi tailscale mosh-server rg fzf eza kubectx kubens; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c present"; else bad "$c MISSING"; fi
done
# krew is not a command of its own — it is a kubectl plugin, so "installed" and
# "reachable" are two separate questions. This is the first one. The second
# (does kubectl actually find it on PATH) can only be answered from an
# interactive shell and lives in the Shell + dotfiles section below: 40_path.sh
# is sourced from .zshrc, so `kubectl krew version` run from *this* script would
# report "unknown command" no matter how correct the config is.
if [ -x "${KREW_ROOT:-$HOME/.krew}/bin/kubectl-krew" ]; then
  ok "krew present"
else
  bad "krew MISSING"
fi
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
# Everything that can only be observed from an INTERACTIVE shell is probed here,
# once, because that probe is by far the most expensive thing this script does.
#
# setsid is load-bearing, and redirecting stdin is not enough on its own.
# `zsh -i` starts zle, and zle opens /dev/tty *directly* — so run from a
# terminal it grabs the tty and blocks even with all three fds redirected.
# `timeout` alone cannot rescue it either, because interactive shells ignore
# SIGTERM. setsid drops the controlling terminal so there is no /dev/tty to
# open; -k adds a SIGKILL backstop. Without this the substitution yields
# nothing and every check below reports a failure no matter how well the shell
# is configured.
#
# The shell does not exit on its own even with -c, so `timeout` killing it is
# the NORMAL outcome — the output has already been flushed by then. Each value
# is tagged so one hung line can't be mistaken for another's answer.
INTERACTIVE_PROBE="$(
  setsid timeout -k 2 10 zsh -i -c '
    print -r -- "PROMPTLEN=${#PROMPT}"
    print -r -- "KALIAS=${aliases[k]:-}"
    print -r -- "KREWPATH=${commands[kubectl-krew]:-}"
  ' </dev/null 2>/dev/null
)"
probe_value() { printf '%s\n' "$INTERACTIVE_PROBE" | sed -n "s/^$1=//p" | tail -n1; }

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
# The `k` alias is interactive-only (50_kube.sh is guarded), so it cannot be
# checked with `zsh -c` — that never reads .zshrc at all and would always
# report it missing. Hence the interactive probe above.
case "$(probe_value KALIAS)" in
  *kubectl*) ok "kubectl is aliased to 'k' in interactive shells" ;;
  *) bad "'k' is not aliased to kubectl — check ~/.config/shell/source/50_kube.sh" ;;
esac
# Same reason this is probed rather than tested directly: 40_path.sh is sourced
# from .zshrc, so ~/.krew/bin is on the interactive PATH only. kubectl finds
# plugins by scanning PATH for `kubectl-<name>`, so resolving `kubectl-krew` in
# the interactive shell is exactly the question — an installed binary that PATH
# never exposes leaves `kubectl krew` reporting "unknown command".
if [ -n "$(probe_value KREWPATH)" ]; then
  ok "kubectl finds krew on the interactive PATH"
elif [ -x "${KREW_ROOT:-$HOME/.krew}/bin/kubectl-krew" ]; then
  bad "krew is installed but not on the interactive PATH — check the krew entry"
  bad "  in ~/.config/shell/source/40_path.sh, then 'chezmoi apply'"
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
for s in claude-attach claude-env claude-vscode; do
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
# A bare zsh prompt is "%m%# " (6 chars); starship's is far longer. Measured by
# the single interactive probe near the top of this script — see the comment
# there for why that needs setsid.
PROMPT_LEN="$(probe_value PROMPTLEN)"
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
section "Lab subnet routing (LAN/Teleport clients -> tun0)"
LAB_SUBNET="10.47.0.0/16"
LAB_DNS="172.21.0.90"

# ip_forward being 1 right now proves nothing on its own: dockerd sets it at
# start-up, so the box can read as "forwarding" while no config asks for it and
# a Docker-less boot silently drops it. The config file is the real check.
if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
  if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward=1' /etc/sysctl.d/99-lab-routing.conf 2>/dev/null; then
    ok "IP forwarding on and set in /etc/sysctl.d/99-lab-routing.conf"
  else
    warn "IP forwarding is on at runtime but nothing configures it — that is"
    warn "  dockerd's side effect, and it does not survive a Docker-less boot;"
    warn "  re-run server-bootstrap.sh"
  fi
else
  bad "IP forwarding is off — lab traffic cannot be routed through this box"
fi

# The unit owns the rules, so its state is the first thing to ask about.
if systemctl is-enabled --quiet lab-routing.service 2>/dev/null; then
  ok "lab-routing.service enabled (rules reinstalled on boot)"
else
  bad "lab-routing.service not enabled — forwarding will not survive a reboot"
fi
if systemctl is-active --quiet lab-routing.service 2>/dev/null; then
  ok "lab-routing.service active"
else
  bad "lab-routing.service not active — check: journalctl -u lab-routing.service"
fi

# Reading the live filter/nat tables is the only root-only thing this script
# does, so escalation is scoped to exactly here — never the whole script, which
# would take root's empty environment as evidence of a broken setup.
# Interactively that means one password prompt; unattended it falls back to
# `sudo -n` and, failing that, skips rather than fails.
if [ -t 0 ] && sudo -v 2>/dev/null; then
  LAB_SUDO="sudo"
elif sudo -n true 2>/dev/null; then
  LAB_SUDO="sudo -n"
else
  LAB_SUDO=""
fi

if [ -n "$LAB_SUDO" ]; then
  # -C asks the kernel whether the exact rule is loaded, which is the only
  # question that matters. Config files can say anything — that is precisely
  # how the ufw attempt failed: rules written, ufw disabled, nothing applied.
  if $LAB_SUDO iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null; then
    ok "MASQUERADE on tun0 is loaded"
  else
    bad "no MASQUERADE on tun0 — the lab has no route back to LAN/Teleport"
    bad "  clients, so forwarded traffic dies on the return trip"
  fi

  if $LAB_SUDO iptables -C FORWARD -j LAB-ROUTING 2>/dev/null; then
    ok "FORWARD jumps to the LAB-ROUTING chain"
  else
    bad "FORWARD does not jump to LAB-ROUTING — the rules exist but are never"
    bad "  reached; systemctl restart lab-routing.service"
  fi

  # Deliberately not matched on an inbound interface: clients arrive on either
  # VLAN leg, and pinning these to one silently broke the other.
  for dest in "$LAB_SUBNET" "$LAB_DNS"; do
    if $LAB_SUDO iptables -C LAB-ROUTING -o tun0 -d "$dest" -j ACCEPT 2>/dev/null; then
      ok "forwarding to $dest allowed"
    else
      bad "no forward rule for $dest — Docker sets the FORWARD policy to DROP,"
      bad "  so this is dropped silently; systemctl restart lab-routing.service"
    fi
  done

  if $LAB_SUDO iptables -C LAB-ROUTING -i tun0 -m conntrack \
       --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    ok "return path from tun0 allowed"
  else
    bad "no return rule — replies from the lab are dropped;"
    bad "  systemctl restart lab-routing.service"
  fi

  # Without this, ping and DNS work while large transfers hang — the failure
  # that looks like anything except an MTU problem.
  if $LAB_SUDO iptables -t mangle -C FORWARD -o tun0 -p tcp \
       --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1350 2>/dev/null; then
    ok "TCP MSS clamped on traffic entering tun0"
  else
    bad "no MSS clamp for tun0 — tun0's MTU is 1500, so forwarded TCP will"
    bad "  blackhole on large segments; systemctl restart lab-routing.service"
  fi
else
  warn "skipped the firewall checks — no usable sudo. Check by hand with:"
  warn "  sudo iptables -t nat -S POSTROUTING | grep tun0"
  warn "  sudo iptables -S LAB-ROUTING"
fi

# Only meaningful while the tunnel is up: the prefixes are covered by routes
# OpenVPN installs itself, so with tun0 down there is nothing to look at.
if ip link show tun0 >/dev/null 2>&1; then
  for dest in "10.47.0.224" "$LAB_DNS"; do
    if ip route get "$dest" 2>/dev/null | grep -q 'dev tun0'; then
      ok "$dest routes via tun0"
    else
      bad "$dest does not route via tun0 — check what the tunnel pushed:"
      bad "  journalctl -u openvpn-client@client-env | grep PUSH_REPLY"
    fi
  done
else
  ok "tun0 absent — skipping route checks (normal; 'client-vpn up' to connect)"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mSummary:\033[0m %d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
