#!/usr/bin/env bash
# Applies the chezmoi source twice and asserts the second run is a no-op, then
# checks that the role's exclusions actually took effect. Runs inside the
# container built by ../Dockerfile; see that file for usage.
set -euo pipefail

ROLE="${ROLE:-restricted}"
SRC="$HOME/dotfiles-src"
CFG="$HOME/.config/chezmoi/chezmoi.toml"

mkdir -p "$(dirname "$CFG")"
cat >"$CFG" <<EOF
sourceDir = "${SRC}"

[data]
  role = "${ROLE}"
EOF

echo "== role: ${ROLE} =="

echo "-- first apply --"
chezmoi apply

echo "-- second apply (must be a no-op) --"
CHANGES="$(chezmoi apply --dry-run --verbose 2>&1 || true)"
if [ -n "$(printf '%s' "$CHANGES" | tr -d '[:space:]')" ]; then
  echo "FAIL: second apply is not idempotent; it would still change:"
  printf '%s\n' "$CHANGES"
  exit 1
fi
echo "OK: idempotent"

# --- role exclusions -------------------------------------------------------
# These are SSH clients (and their aliases) — they run claude on the SERVER and
# nothing locally, so every role gets them, including the restricted ones that
# must never have the CLI installed. What a restricted role must NOT get is
# claude-session, the wrapper that execs claude in the current shell.
client_files=(.local/bin/claude-attach .local/bin/claude-env .local/bin/claude-vscode .config/shell/source/70_claude.sh)
fail=0

expect_absent() {
  if [ -e "$HOME/$1" ]; then echo "FAIL: $1 should NOT exist for role=$ROLE"; fail=1
  else echo "OK: $1 correctly absent"; fi
}
expect_present() {
  if [ -e "$HOME/$1" ]; then echo "OK: $1 present"
  else echo "FAIL: $1 SHOULD exist for role=$ROLE"; fail=1; fi
}

for f in "${client_files[@]}"; do expect_present "$f"; done

# claude-session runs claude in-process, so it belongs only where the CLI is
# installed. The point of the whole exclusion mechanism: an unrecognised role
# must behave like the work laptop, not like the server.
if [ "$ROLE" = "server" ]; then expect_present .local/bin/claude-session
else expect_absent .local/bin/claude-session; fi

# Same rule, same reason: claude-open starts a session running claude here, and
# claude-telegram-bot is the phone entry point that calls it. Both are
# server-only — a bot token on a laptop would be attack surface with nothing to
# gain, since that laptop has no Claude Code to open.
for f in .local/bin/claude-open .local/bin/claude-telegram-bot; do
  if [ "$ROLE" = "server" ]; then expect_present "$f"; else expect_absent "$f"; fi
done

# The VS Code auto-install guard is the counterpart — deployed exactly where
# Claude Code must never be installed.
case "$ROLE" in
  server|personal) expect_absent .config/shell/source/70_work_guard.sh ;;
  *)               expect_present .config/shell/source/70_work_guard.sh ;;
esac

if [ "$ROLE" = "personal" ]; then expect_present .local/bin/paste-image
else expect_absent .local/bin/paste-image; fi

if [ "$ROLE" = "server" ]; then expect_present .config/shell/source/60_browser.sh
else expect_absent .config/shell/source/60_browser.sh; fi

# Applies to every role: the general layer, and the tier-1 env file.
expect_present .zshenv
expect_present .zshrc
expect_present .gitconfig
expect_present .config/shell/source/50_aliases.sh

# --- shell actually loads --------------------------------------------------
echo "-- interactive zsh smoke test --"
if zsh -i -c 'exit 0' 2>&1 | grep -vE "can't change option: zle" | grep -q .; then
  echo "FAIL: interactive zsh emitted errors:"
  zsh -i -c 'exit 0' 2>&1 | grep -vE "can't change option: zle"
  fail=1
else
  echo "OK: interactive zsh starts cleanly"
fi

# Tier 1 must provide PATH to NON-interactive shells — the bug that motivated
# splitting .zshenv out of .zshrc.
if zsh -c 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0;; *) exit 1;; esac'; then
  echo "OK: ~/.local/bin on PATH in a non-interactive shell"
else
  echo "FAIL: ~/.local/bin missing from PATH in non-interactive zsh"
  fail=1
fi

exit "$fail"
