#!/usr/bin/env bash
#
# Idempotent bootstrap for the work MacBook Pro.
#
# Constraint #1: this machine NEVER installs or runs Claude Code, CLI or IDE
# extension. It is a pure client — SSH, Mosh, Ghostty, VS Code Remote-SSH —
# nothing that executes Claude Code LOCALLY. Do not add a Claude Code install
# step to this script.
#
# Reaching the session running on the server is not a violation of that and is
# the reason this machine exists: claude-attach/claude-env ship here, they just
# SSH. The check at the bottom of this script verifies the constraint the way
# it is actually stated — nothing installed — rather than by the absence of
# files named claude-*.
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

# Kubernetes tooling — general layer, nothing Claude-related, so it applies here
# exactly as on the other two machines. The probe argument matters more on this
# laptop than elsewhere: IT-managed machines often already have a kubectl
# installed outside Homebrew, and `brew install` would otherwise add a second
# copy that shadows it.
log "Installing Kubernetes tools"
ensure_formula kubernetes-cli          kubectl
ensure_formula krew
ensure_formula kubectx                 kubectx

# ensure_cask skips apps already installed outside brew. A work laptop very
# likely has VS Code installed by IT or by hand, and `brew install --cask`
# aborts on an existing app — which under `set -e` would kill this script
# before it ever reaches chezmoi.
log "Installing apps"
ensure_cask ghostty              "Ghostty.app"
ensure_cask visual-studio-code   "Visual Studio Code.app"
ensure_cask font-meslo-lg-nerd-font

# The "never auto-install the Claude Code IDE extension" guard is NOT patched
# in here. chezmoi copies the managed dot_config/vscode/settings.json over the
# real one at ~/Library/Application Support/Code/User/, so anything written
# directly to the real file gets replaced by the chezmoi apply below. The setting
# (claude-code.autoInstallIdeExtension: false) therefore lives in the managed
# file itself, and the shell config exports CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1
# for the "work" role.

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/chezmoi-apply.sh
source "${SCRIPT_DIR}/lib/chezmoi-apply.sh"
# role=work selects the restricted layer set (see dotfiles/.chezmoiignore.tmpl):
# the general layer plus the SSH-client helpers, minus claude-session and plus
# the VS Code auto-install guard. No hostname has to match for this to work —
# and an unset role falls back to "restricted", which resolves identically.
apply_dotfiles work "$REPO_ROOT"

# Split DNS for the lab's internal zone. This machine is the one that actually
# needs it: it reaches the lab over Teleport, through the routing the server
# provides, and without this a browser can only use bare addresses.
# shellcheck source=lib/lab-dns.sh
source "${SCRIPT_DIR}/lib/lab-dns.sh"
install_lab_resolver

# What gets verified here is constraint #1 itself — that no Claude Code CLI or
# IDE extension is INSTALLED — not the absence of files with "claude" in the
# name. claude-attach and claude-env do ship here: they are SSH clients that
# run claude on the server, which is the whole point of this machine. The file
# that would run it locally (claude-session) is server-only.
log "Verifying Claude Code is not installed on this machine"
LEAKED=0

if command -v claude >/dev/null 2>&1; then
  log "ERROR: a 'claude' executable is on PATH at $(command -v claude) — this machine must never have the CLI installed"
  LEAKED=1
fi

# Not on PATH is not the same as not installed: the native installer and npm
# both have well-known locations that a login shell might not have picked up.
for f in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
         "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
  if [ -e "$f" ]; then
    log "ERROR: ${f} exists — uninstall the Claude Code CLI from this machine"
    LEAKED=1
  fi
done

# The IDE extension is the other install path, and the one that appears without
# anyone deciding to install it. autoInstallIdeExtension:false in the managed
# settings.json plus CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1 are meant to prevent
# it; this checks whether they held.
if command -v code >/dev/null 2>&1; then
  if code --list-extensions 2>/dev/null | grep -qi '^anthropic\.claude-code$'; then
    log "ERROR: the Claude Code VS Code extension is installed — remove it with: code --uninstall-extension anthropic.claude-code"
    LEAKED=1
  fi
fi

# The one local file that would execute claude. Its presence means the role in
# ~/.config/chezmoi/chezmoi.toml is wrong, not that anything is installed yet.
if [ -e "$HOME/.local/bin/claude-session" ]; then
  log "ERROR: ~/.local/bin/claude-session exists — check [data] role in ~/.config/chezmoi/chezmoi.toml"
  LEAKED=1
fi

if [ "$LEAKED" -eq 0 ]; then
  log "OK: no Claude Code CLI or IDE extension on this machine"
fi

log "Done. See docs/client-work-setup.md for the OpenVPN import and other manual steps."
