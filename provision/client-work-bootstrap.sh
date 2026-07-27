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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/brew.sh
source "${SCRIPT_DIR}/lib/brew.sh"

log "Updating Homebrew"
brew update

# Same general-layer CLI tooling as every other machine — this laptop is
# excluded from the Claude Code layer, not from the terminal/editor defaults.
# Deliberately NO tailscale here (constraint #2).
log "Installing CLI tools"
ensure_formula mosh                    mosh
ensure_formula chezmoi                 chezmoi
ensure_formula ripgrep                 rg
ensure_formula fd                      fd
ensure_formula bat                     bat
ensure_formula eza                     eza
ensure_formula fzf                     fzf
ensure_formula starship                starship
ensure_formula zsh-autosuggestions
ensure_formula zsh-syntax-highlighting

# ensure_cask skips apps already installed outside brew. A work laptop very
# likely has VS Code installed by IT or by hand, and `brew install --cask`
# aborts on an existing app — which under `set -e` would kill this script
# before it ever reaches chezmoi.
log "Installing apps"
ensure_cask ghostty              "Ghostty.app"
ensure_cask visual-studio-code   "Visual Studio Code.app"
ensure_cask font-meslo-lg-nerd-font

# The "never auto-install the Claude Code IDE extension" guard is NOT patched
# in here. chezmoi symlinks the real settings.json at
# ~/Library/Application Support/Code/User/ to the managed
# dot_config/vscode/settings.json, so anything written directly to the real
# file gets replaced by the chezmoi apply below. The setting
# (claude-code.autoInstallIdeExtension: false) therefore lives in the managed
# file itself, and the shell config exports CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1
# for the "work" role.

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/chezmoi-apply.sh
source "${SCRIPT_DIR}/lib/chezmoi-apply.sh"
# role=work is what excludes the Claude-specific files (see
# dotfiles/.chezmoiignore.tmpl). No hostname has to match for this to work —
# and an unset role would fall back to "restricted", which excludes them too.
apply_dotfiles work "$REPO_ROOT"

log "Verifying no Claude Code artifacts landed on this machine"
LEAKED=0
for f in "$HOME/.local/bin/claude-attach" "$HOME/.local/bin/claude-env" \
         "$HOME/.local/bin/paste-image" "$HOME/.config/shell/source/70_claude.sh"; do
  if [ -e "$f" ]; then
    log "ERROR: ${f} exists on this machine — check [data] role in ~/.config/chezmoi/chezmoi.toml"
    LEAKED=1
  fi
done
if [ "$LEAKED" -eq 0 ]; then
  log "OK: no Claude-specific files present"
fi

log "Done. See docs/client-work-setup.md for the OpenVPN import and other manual steps."
