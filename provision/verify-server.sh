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
for c in zsh tmux herdr git docker kubectl terraform go chezmoi tailscale mosh-server rg fzf eza kubectx kubens; do
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
  bad "claude MISSING — herdr-server.service has nothing to start"
fi
if command -v codex >/dev/null 2>&1; then
  ok "codex present ($(codex --version 2>/dev/null || echo '?'))"
else
  bad "codex MISSING — re-run server-bootstrap.sh"
fi
# `codex` being on PATH is not enough: the app-server daemon only starts from
# the installer-managed copy at this fixed path, so an npm-installed Codex
# passes the check above and still cannot be driven from the phone.
if [ -x "$HOME/.codex/packages/standalone/current/codex" ]; then
  ok "codex is the standalone (installer-managed) build"
else
  bad "codex is NOT the standalone build — the app-server daemon cannot start from it."
fi
if [ -e "$HOME/.npm-global/bin/codex" ]; then
  warn "an npm-managed codex is still installed — PATH order decides which one runs ('npm uninstall -g @openai/codex')"
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
systemctl is-enabled --quiet herdr-server.service 2>/dev/null \
  && ok "herdr-server.service enabled (starts on boot)" \
  || bad "herdr-server.service NOT enabled — it will not come back after a reboot"
systemctl is-active --quiet herdr-server.service 2>/dev/null \
  && ok "herdr-server.service active" || bad "herdr-server.service not active"

# claude-tmux.service is left on disk but disabled — it is the way back to tmux,
# re-enabled by hand. Enabled here means both stacks would fight for the session
# on the next boot.
if systemctl is-enabled --quiet claude-tmux.service 2>/dev/null; then
  warn "claude-tmux.service is still enabled — herdr owns the session now"
  printf '        fix: sudo systemctl disable --now claude-tmux.service\n'
fi

# Leftovers from the tmux era. claude-main came back from the unit above; cc-*
# sessions were started by the old tmux claude-open and nothing manages them
# any more, so they will sit there holding a claude process forever. Reported
# rather than killed: they may still hold a conversation, and that is a call
# for a person to make, not for a health check.
if command -v tmux >/dev/null 2>&1; then
  STALE="$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | grep -E '^(claude-main|claude-env|cc-)' || true)"
  if [ -n "$STALE" ]; then
    warn "tmux sessions left over from before herdr took over:"
    printf '        %s\n' $STALE
    printf '        check one with: tmux capture-pane -p -t <name>\n'
    printf '        remove one with: tmux kill-session -t <name>\n'
  fi
fi

# Unlike the tmux unit, `systemctl is-active` here IS meaningful: Type=exec
# means the supervised process is the server itself. What it still cannot tell
# you is whether the session inside has anything in it, which is what follows.
if ! command -v herdr >/dev/null 2>&1; then
  bad "herdr not on PATH — the session cannot be inspected"
elif ! herdr status server >/dev/null 2>&1; then
  bad "the herdr server is not answering on its socket"
else
  ok "herdr server responding ($(herdr --version 2>/dev/null))"

  # Ask herdr directly rather than inspecting processes. The tmux version had
  # to walk the pane's process tree, because the unit ran `claude; exec $SHELL`
  # and tmux only reports the pane's own process — so claude, being a child,
  # looked absent. herdr tracks the agent itself and reports its lifecycle
  # state, so there is nothing to infer.
  WS_JSON="$(herdr workspace list 2>/dev/null || echo '{}')"
  if printf '%s' "$WS_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ws = d.get("result", {}).get("workspaces", [])
sys.exit(0 if any(w.get("label") == "claude-main" for w in ws) else 1)
' 2>/dev/null; then
    ok "workspace 'claude-main' exists"

    AGENT_STATE="$(herdr agent list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for a in d.get("result", {}).get("agents", []):
    if a.get("agent") == "claude" and a.get("cwd", "").endswith("/workspace"):
        print(a.get("agent_status", "unknown")); break
' 2>/dev/null)"

    if [ -n "${AGENT_STATE:-}" ]; then
      ok "claude is running in claude-main (state: ${AGENT_STATE})"
    else
      warn "claude-main exists but no claude agent is running in it"
      # Most common cause is unchanged from the tmux era: claude hit the
      # interactive trust prompt for its working directory, got no answer and
      # exited. herdr leaves the pane's shell behind, so the workspace survives
      # and only the agent is missing — which is exactly this branch.
      PANE_DIR="$HOME/workspace"
      printf '        expected cwd: %s\n' "$PANE_DIR"
      if [ -f "$HOME/.claude.json" ] && command -v python3 >/dev/null 2>&1; then
        python3 - "$HOME/.claude.json" "$PANE_DIR" <<'PYEOF' 2>/dev/null
import json, sys
cfg, d = sys.argv[1], sys.argv[2]
p = json.load(open(cfg)).get("projects", {}).get(d, {})
if p.get("hasTrustDialogAccepted") is True:
    print("        that directory IS trusted — check the pane for the real error:")
    print("        herdr pane list, then: herdr pane read <pane-id>")
else:
    print("        that directory is NOT trusted by Claude Code, which is very likely why it exited.")
    print("        fix: re-run server-bootstrap.sh, or run 'claude' there once and accept the prompt")
PYEOF
      fi
      printf '        restart it with: herdr-main-workspace\n'
    fi
  else
    bad "workspace 'claude-main' does not exist — run herdr-main-workspace"
  fi
fi

# ---------------------------------------------------------------------------
section "Telegram bot (phone entry point)"
for s in claude-open codex-open codex-sessions claude-telegram-bot; do
  [ -x "$HOME/.local/bin/$s" ] && ok "$s installed and executable" \
    || bad "$s missing from ~/.local/bin — run chezmoi apply"
done
TG_SECRETS="$HOME/.secrets/telegram-bot"
if [ -r "$TG_SECRETS" ]; then
  perms="$(stat -c %a "$TG_SECRETS" 2>/dev/null || echo '?')"
  [ "$perms" = "600" ] && ok "~/.secrets/telegram-bot is 0600" \
    || bad "~/.secrets/telegram-bot is 0$perms — it holds a bearer token, chmod 600 it"
  # Without an allow-list every Telegram user who finds the bot could run
  # claude-open on this box, so an empty value is a real finding, not a nit.
  if grep -qE '^[[:space:]]*export[[:space:]]+TELEGRAM_ALLOWED_CHAT_IDS=.+' "$TG_SECRETS"; then
    ok "TELEGRAM_ALLOWED_CHAT_IDS is set"
  else
    bad "TELEGRAM_ALLOWED_CHAT_IDS is empty or missing — the bot would accept"
    bad "  commands from anyone who messages it"
  fi
  systemctl is-enabled --quiet claude-telegram-bot.service 2>/dev/null \
    && ok "claude-telegram-bot.service enabled (starts on boot)" \
    || bad "claude-telegram-bot.service NOT enabled — re-run server-bootstrap.sh"
  systemctl is-active --quiet claude-telegram-bot.service 2>/dev/null \
    && ok "claude-telegram-bot.service active" \
    || bad "claude-telegram-bot.service not active — check: journalctl -u claude-telegram-bot"
else
  warn "no ~/.secrets/telegram-bot — the phone entry point is not configured"
  warn "  (expected if unused; see docs/server-setup.md)"
fi

# ---------------------------------------------------------------------------
section "Codex app-server daemon (ChatGPT app entry point)"
# The daemon is what the ChatGPT app pairs with and what every `codex --remote
# unix://` session attaches to. Nothing about a Codex session LOOKS wrong when
# this is down — sessions still start and run on the server, they are simply
# invisible from the phone — so it is worth checking explicitly.
systemctl is-enabled --quiet codex-app-server.service 2>/dev/null \
  && ok "codex-app-server.service enabled (starts on boot)" \
  || bad "codex-app-server.service NOT enabled — re-run server-bootstrap.sh"
# No is-active check: the unit is Type=oneshot and the daemon detaches, so
# systemd's view of it says nothing useful. Ask Codex instead.
if daemon_json="$(codex app-server daemon version 2>/dev/null)"; then
  case "$daemon_json" in
    *'"status":"running"'*) ok "app-server daemon running ($(printf '%s' "$daemon_json" | sed -n 's/.*"appServerVersion":"\([^"]*\)".*/\1/p'))" ;;
    *) bad "app-server daemon not running — start it: sudo systemctl restart codex-app-server" ;;
  esac
else
  # restart, not start, and not `codex app-server daemon start` by hand: the
  # unit is RemainAfterExit so start is a no-op, and a daemon started from this
  # shell lives in the login session instead of the unit.
  bad "app-server daemon not reachable — start it: sudo systemctl restart codex-app-server"
fi
# Remote control is a per-machine enrollment with the ChatGPT backend, and it
# is rejected outright for accounts without MFA ("403 ... Multi-factor
# authentication required"), so this can fail while everything local is fine.
if [ "$(cat "$HOME/.codex/app-server-daemon/settings.json" 2>/dev/null | tr -d ' \n')" = '{"remoteControlEnabled":true}' ]; then
  # Enabled is not the same as enrolled: the flag is local, while enrollment is
  # a call to the ChatGPT backend that fails for its own reasons (no login, no
  # MFA on the account). Asking the daemon is the only way to tell them apart,
  # and the difference is invisible from the phone — sessions simply never
  # appear.
  # `remote-control start` exits 0 whether or not the connection came up, and
  # it prints two different things: a human "Error: ... the connection is
  # errored." with a tty attached, and the --json object without one. So the
  # status field is what gets read, from the redirected form.
  rc_out="$(timeout 60 codex remote-control start --json 2>&1 </dev/null)"
  case "$rc_out" in
    *'"status":"connected"'*)
      ok "remote control enabled and connected" ;;
    *'not managed by codex app-server daemon'*)
      # The pid file was dropped as stale (a clock step after start does it —
      # see lib/codex.sh), so no codex command can manage this daemon now.
      bad "the daemon is running but Codex has disowned it — remote control and pairing refuse"
      bad "  fix: sudo systemctl restart codex-app-server" ;;
    *)
      bad "remote control enabled but NOT connected — the ChatGPT app sees nothing:"
      bad "  ${rc_out}"
      bad "  a 403 'Multi-factor authentication required' at enrollment means the"
      bad "  account has no MFA: enable 2FA, codex login, then"
      bad "  sudo systemctl restart codex-app-server" ;;
  esac
else
  warn "remote control not enabled — the ChatGPT app cannot see sessions on this box"
  warn "  enable it: sudo systemctl restart codex-app-server  (the unit runs bootstrap --remote-control)"
fi
# Codex sandboxes every command it runs through a bundled bubblewrap, which
# cannot create user namespaces on stock Ubuntu 24.04 without this profile.
# Tested by running something in the sandbox rather than by reading
# /etc/apparmor.d or aa-status: whether the profile is LOADED needs root to
# observe, and "a trivial command completes" is the property actually wanted.
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
  if command -v codex >/dev/null 2>&1; then
    sandbox_out="$(timeout 60 codex sandbox -- /bin/true 2>&1)"
    if printf '%s' "$sandbox_out" | grep -q 'bwrap:'; then
      bad "Codex's sandbox cannot start commands: ${sandbox_out}"
      bad "  the AppArmor profile is missing or not loaded — re-run server-bootstrap.sh"
    else
      ok "Codex's sandbox can run commands (AppArmor profile in effect)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "Blog writing flow (dev-log -> post)"
# The clones are provisioned by lib/repos.sh, which warns rather than aborts
# when GitHub credentials are missing — so a missing repo here is the expected
# way that failure surfaces. See docs/blog-workflow.md.
if [ -d "$HOME/dev-log/.git" ]; then
  ok "~/dev-log cloned"
  [ -d "$HOME/dev-log/pitches" ] \
    && ok "~/dev-log/pitches exists (brief staging area)" \
    || warn "~/dev-log/pitches missing — created by the first /post-brief"
else
  bad "~/dev-log NOT cloned — re-run server-bootstrap.sh once credentials exist"
fi

# Must be under ~/workspace specifically: that is where claude-telegram-bot
# resolves /cc_open <dir>, which is the phone entry point to the whole flow.
if [ -d "$HOME/workspace/warroyo-blog/.git" ]; then
  ok "~/workspace/warroyo-blog cloned (reachable as /cc_open warroyo-blog)"
  [ -f "$HOME/workspace/warroyo-blog/.claude/commands/post-scaffold.md" ] \
    && ok "blog repo carries its own /post-scaffold + /post-ship" \
    || warn "blog repo has no .claude/commands — pull the latest main"
else
  bad "~/workspace/warroyo-blog NOT cloned — re-run server-bootstrap.sh"
fi

# The voice skill. Checked through the link, not just the clone: a checkout
# that ~/.claude/skills does not point at is invisible to Claude Code.
PROSE_REPO="$HOME/workspace/will-prose"
PROSE_LINK="$HOME/.claude/skills/will-prose"
if [ -d "$PROSE_REPO/.git" ]; then
  ok "~/workspace/will-prose cloned"
  if [ -L "$PROSE_LINK" ] && [ "$(readlink -f "$PROSE_LINK")" = "$(readlink -f "$PROSE_REPO")" ] \
     && [ -f "$PROSE_LINK/SKILL.md" ]; then
    ok "will-prose skill linked into ~/.claude/skills"
  else
    bad "~/.claude/skills/will-prose does not point at ~/workspace/will-prose —"
    bad "  re-run server-bootstrap.sh"
  fi
else
  bad "~/workspace/will-prose NOT cloned — re-run server-bootstrap.sh once credentials exist"
fi

for cmd in post-ideas post-brief; do
  [ -f "$HOME/.claude/commands/${cmd}.md" ] \
    && ok "/${cmd} applied" \
    || bad "/${cmd} MISSING — run 'chezmoi apply'"
done

# Checked NON-interactively on purpose, and this is the whole point of the
# check: it lives in .zshenv rather than a .zshrc fragment because herdr starts
# `claude` under systemd, which never reads .zshrc. If this only passed under
# `zsh -i`, the phone-driven sessions would be exactly the ones without it.
BLOG_ENV="$(zsh -c 'printf %s "${DEV_LOG_PITCHES:-}"' 2>/dev/null)"
if [ -n "$BLOG_ENV" ]; then
  ok "DEV_LOG_PITCHES set non-interactively ($BLOG_ENV)"
elif [ ! -d "$HOME/dev-log" ]; then
  warn "DEV_LOG_PITCHES unset because ~/dev-log is missing — clone it first"
else
  bad "DEV_LOG_PITCHES not set despite ~/dev-log existing — check ~/.zshenv"
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
section "Lab subnet routing (LAN/Teleport/tailnet clients -> tun0)"
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

# Advertising the prefix and having it APPROVED are two different things, and
# the gap between them is silent: this box looks configured, the client sees no
# route at all, and nothing anywhere logs a complaint. Check both separately.
if tailscale status >/dev/null 2>&1; then
  # Both of these read a named key rather than grepping for the CIDR: the
  # prefix appears in more than one place in that JSON, so a bare grep would
  # report "advertised" on the strength of some unrelated field.
  if tailscale debug prefs 2>/dev/null \
       | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in (json.load(sys.stdin).get("AdvertiseRoutes") or []) else 1)' \
           "$LAB_SUBNET" 2>/dev/null; then
    ok "${LAB_SUBNET} is advertised to the tailnet"
    if tailscale status --json 2>/dev/null \
         | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in (json.load(sys.stdin).get("Self",{}).get("PrimaryRoutes") or []) else 1)' \
             "$LAB_SUBNET" 2>/dev/null; then
      ok "${LAB_SUBNET} is approved — tailnet clients receive the route"
    else
      bad "${LAB_SUBNET} is advertised but NOT approved, so no tailnet client"
      bad "  gets it. Approve it in the admin console (Machines -> this host ->"
      bad "  Edit route settings) or via autoApprovers in the policy file."
    fi
  else
    bad "${LAB_SUBNET} is not advertised to the tailnet — the personal laptop"
    bad "  reaches the lab only from the LAN; re-run server-bootstrap.sh"
  fi
else
  warn "tailscale is down — skipping the subnet-route checks"
fi

# ---------------------------------------------------------------------------
section "Split DNS for set.lab (dnsmasq on :5300)"
LAB_ZONE="set.lab"
LAB_DNS_PORT="5300"
DNSMASQ_CONF="/etc/dnsmasq.d/lab-split-dns.conf"

if [ -f "$DNSMASQ_CONF" ]; then
  ok "$DNSMASQ_CONF present"

  # Port 53 here would defeat the entire point of this: the reason the zone
  # moved off 53 is that gateways and hotel APs DNAT it to themselves.
  if grep -qE "^[[:space:]]*port=${LAB_DNS_PORT}[[:space:]]*$" "$DNSMASQ_CONF"; then
    ok "listening port is ${LAB_DNS_PORT}, not 53"
  else
    bad "dnsmasq is not configured for port ${LAB_DNS_PORT} — on 53 it will be"
    bad "  intercepted by any gateway that redirects DNS; re-run server-bootstrap.sh"
  fi

  # An upstream for anything other than the lab zone would make this an open
  # recursive resolver on every LAN address it binds.
  if grep -qE "^[[:space:]]*no-resolv[[:space:]]*$" "$DNSMASQ_CONF" \
     && ! grep -qE '^[[:space:]]*server=[^/]' "$DNSMASQ_CONF"; then
    ok "no general upstream — forwards ${LAB_ZONE} only, not an open resolver"
  else
    bad "dnsmasq has a general upstream — this box would answer recursive"
    bad "  queries for anyone on the LAN; re-run server-bootstrap.sh"
  fi
else
  bad "no $DNSMASQ_CONF — clients have nothing to point at; run server-bootstrap.sh"
fi

systemctl is-enabled --quiet dnsmasq 2>/dev/null \
  && ok "dnsmasq enabled (starts on boot)" \
  || bad "dnsmasq NOT enabled — split DNS dies at the next reboot"
systemctl is-active --quiet dnsmasq 2>/dev/null \
  && ok "dnsmasq active" \
  || bad "dnsmasq not active — check: journalctl -u dnsmasq -n 30"

# Bound where clients actually arrive. Loopback-only would pass every check
# above and still answer nobody.
dns_listeners="$(ss -lnu 2>/dev/null \
  | awk -v p=":${LAB_DNS_PORT}\$" '$4 ~ p {print $4}' | sort -u)"
if [ -n "$dns_listeners" ]; then
  ok "UDP listeners on ${LAB_DNS_PORT}: $(printf '%s ' $dns_listeners)"
  if printf '%s\n' "$dns_listeners" | grep -qv '^127\.'; then
    ok "  at least one LAN address is bound"
  else
    bad "  loopback ONLY — no client can reach this. The LAN address probably"
    bad "  changed since bootstrap; re-run server-bootstrap.sh"
  fi
  # The tailnet address is worth naming rather than letting "at least one
  # non-loopback address" cover it: the listen list is built from LAN addresses,
  # which excludes 100.64/10 twice over, so this is the one that goes missing
  # while every other check here passes.
  if [ -n "$TS_IP" ]; then
    if printf '%s\n' "$dns_listeners" | grep -q "^${TS_IP}:"; then
      ok "  tailnet address ${TS_IP} is bound"
    else
      bad "  tailnet address ${TS_IP} is NOT bound, so the personal laptop's"
      bad "  *.set.lab lookups fail while its route to the lab looks perfect."
      bad "  Re-run server-bootstrap.sh with Tailscale up."
    fi
  fi
else
  bad "nothing is listening on UDP ${LAB_DNS_PORT}"
fi

# The end-to-end question, and the only one that catches a tunnel that is up
# but no longer carrying the lab resolver.
if ip link show tun0 >/dev/null 2>&1; then
  if command -v dig >/dev/null 2>&1; then
    if dig +short +time=3 +tries=1 -p "$LAB_DNS_PORT" @127.0.0.1 \
         "auto.gpu.${LAB_ZONE}" 2>/dev/null | grep -qE '^10\.47\.'; then
      ok "auto.gpu.${LAB_ZONE} resolves through dnsmasq into the tunnel"
    else
      bad "auto.gpu.${LAB_ZONE} did not resolve via 127.0.0.1:${LAB_DNS_PORT} —"
      bad "  check the tunnel reaches the lab resolver:"
      bad "    dig @${LAB_DNS} auto.gpu.${LAB_ZONE}"
    fi
  else
    warn "no dig — skipping the live resolution check"
  fi
else
  ok "tun0 absent — skipping the live resolution check ('client-vpn up' first)"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mSummary:\033[0m %d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
