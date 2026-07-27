#!/usr/bin/env bash
# Idempotent bootstrap for the personal MacBook Air — the full Claude Code
# client, reached over Tailscale. Safe to re-run any time.
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

if ! command -v brew >/dev/null 2>&1; then
  log "Homebrew not found. Install it first: https://brew.sh"
  exit 1
fi

log "Updating Homebrew"
brew update

# The ripgrep/fd/bat/eza/fzf set is the general layer's CLI tooling — the
# same tools server-bootstrap.sh installs, so the aliases in dot_zshrc.tmpl
# work identically on every machine.
FORMULAE=(tailscale mosh chezmoi ripgrep fd bat eza fzf
          starship zsh-autosuggestions zsh-syntax-highlighting)
# The Nerd Font is installed on the CLIENTS, not the server: the Mac's
# terminal is what renders glyphs, the headless server draws nothing.
CASKS=(ghostty visual-studio-code font-meslo-lg-nerd-font)

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

log "Enabling the Tailscale background service (interactive login is a separate manual step — see docs/client-personal-setup.md)"
sudo brew services start tailscale >/dev/null 2>&1 || true

if command -v code >/dev/null 2>&1; then
  log "Installing VS Code Remote-SSH extension"
  code --install-extension ms-vscode-remote.remote-ssh --force
else
  log "WARNING: 'code' CLI not on PATH yet. In VS Code, run 'Shell Command: Install code command in PATH' from the command palette, then re-run this script."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/chezmoi-apply.sh
source "${SCRIPT_DIR}/lib/chezmoi-apply.sh"
apply_dotfiles personal "$REPO_ROOT"

log "Done. See docs/client-personal-setup.md for the remaining manual steps (tailscale up, etc.)."
