#!/usr/bin/env bash
#
# Idempotent bootstrap for the work MacBook Pro.
#
# Constraint #1: this machine NEVER installs or runs Claude Code, CLI or IDE
# extension. It is a pure client — SSH, Mosh, Ghostty, VS Code Remote-SSH —
# nothing that executes Claude Code. Do not add a Claude Code install step
# to this script.
#
# Constraint #2: this machine uses OpenVPN only, never Tailscale. Do not add
# it to this script.
#
# Everything else here is the same general terminal/editor layer every other
# machine gets — see docs/terminal-and-editor-defaults.md. This machine IS a
# normal chezmoi target; the Claude-specific dotfiles are what get excluded
# (by dotfiles/.chezmoiignore.tmpl), not chezmoi itself.
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

if ! command -v brew >/dev/null 2>&1; then
  log "Homebrew not found. Install it first: https://brew.sh"
  exit 1
fi

log "Updating Homebrew"
brew update

# Same general-layer CLI tooling as every other machine — this laptop is
# excluded from the Claude Code layer, not from the terminal/editor defaults.
FORMULAE=(mosh chezmoi ripgrep fd bat eza fzf)
CASKS=(ghostty visual-studio-code)

for f in "${FORMULAE[@]}"; do
  if brew list --formula "$f" >/dev/null 2>&1; then
    log "$f already installed"
  else
    log "Installing $f"
    brew install "$f"
  fi
done

for c in "${CASKS[@]}"; do
  if brew list --cask "$c" >/dev/null 2>&1; then
    log "$c already installed"
  else
    log "Installing $c"
    brew install --cask "$c"
  fi
done

# The "never auto-install the Claude Code IDE extension" guard is NOT patched
# in here. chezmoi symlinks the real settings.json at
# ~/Library/Application Support/Code/User/ to the managed
# dot_config/vscode/settings.json, so anything written directly to the real
# file gets replaced by the `chezmoi init --apply` below. The setting
# (claude-code.autoInstallIdeExtension: false) therefore lives in the managed
# file itself, and dot_zshrc.tmpl additionally exports
# CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1 on this host.

log "Applying chezmoi dotfiles (Claude-specific files are excluded on this host by dotfiles/.chezmoiignore.tmpl)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
chezmoi init --apply --source="${REPO_ROOT}/dotfiles"

log "Verifying no Claude Code artifacts landed on this machine"
LEAKED=0
for f in "$HOME/.local/bin/claude-attach" "$HOME/.local/bin/claude-env" "$HOME/.local/bin/paste-image"; do
  if [ -e "$f" ]; then
    log "ERROR: ${f} exists on this machine — check hostnames.workLaptop in dotfiles/.chezmoidata.yaml matches '$(hostname)'"
    LEAKED=1
  fi
done
if [ "$LEAKED" -eq 0 ]; then
  log "OK: no Claude-specific files present"
fi

log "Done. See docs/client-work-setup.md for the OpenVPN import and other manual steps."
