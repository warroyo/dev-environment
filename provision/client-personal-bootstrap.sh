#!/usr/bin/env bash
# Idempotent bootstrap for the personal MacBook Air — the full Claude Code
# client, reached over Tailscale. Safe to re-run any time.
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

if ! command -v brew >/dev/null 2>&1; then
  log "Homebrew not found. Install it first: https://brew.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/brew.sh
source "${SCRIPT_DIR}/lib/brew.sh"
# shellcheck source=lib/herdr.sh
source "${SCRIPT_DIR}/lib/herdr.sh"

log "Updating Homebrew"
brew update

# The ripgrep/fd/bat/eza/fzf set is the general layer's CLI tooling — the same
# tools server-bootstrap.sh installs, so the aliases work identically
# everywhere. Second argument is a binary that proves the tool is already
# present some other way.
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

# herdr: the terminal multiplexer being A/B'd against tmux for the persistent
# Claude Code session (see provision/herdr-setup.sh for the server half). It
# belongs in the general layer for the same reason mosh does — it is a client
# that talks to the server and never runs claude locally.
#
# Not a brew formula: there is no official one, and going straight to the
# pinned release binary is what lets lib/herdr.sh verify a checksum and keep
# this machine on the same protocol version as the server. A client/server
# version mismatch is the failure that looks like everything else.
log "Installing herdr"
ensure_herdr

# Kubernetes tooling, matching what server-bootstrap.sh installs by hand there
# (no Homebrew on the server, so those are release tarballs). The `k` alias and
# krew's PATH entry are in the shared shell config, so they light up as soon as
# these exist. kubectl's formula is named kubernetes-cli; kubectx's ships both
# kubectx and kubens.
log "Installing Kubernetes tools"
ensure_formula kubernetes-cli          kubectl
ensure_formula krew
ensure_formula kubectx                 kubectx

# Tailscale on macOS: the GUI app (App Store or direct download) and the
# `tailscale` Homebrew FORMULA are two separate things that each ship their own
# daemon. Installing the formula alongside an existing app gives you two
# tailscaled instances fighting over the same tunnel. If the app is present,
# leave it alone — it is the normal way to run Tailscale on a Mac, and it
# provides the CLI too (see 40_path.sh, which puts it on PATH).
log "Tailscale"
if [ -d "/Applications/Tailscale.app" ] || [ -d "$HOME/Applications/Tailscale.app" ]; then
  echo "  Tailscale.app already installed — not installing the brew formula"
  echo "  (the app ships its own daemon; running both would conflict)"
elif brew list --formula tailscale >/dev/null 2>&1; then
  echo "  tailscale formula already installed"
  sudo brew services start tailscale >/dev/null 2>&1 || true
else
  echo "  installing the Tailscale app"
  ensure_cask tailscale-app "Tailscale.app"
fi

# The Nerd Font is installed on the CLIENTS, not the server: the Mac's terminal
# renders the glyphs, the headless server draws nothing.
log "Installing apps"
ensure_cask ghostty              "Ghostty.app"
ensure_cask visual-studio-code   "Visual Studio Code.app"
ensure_cask font-meslo-lg-nerd-font

if command -v code >/dev/null 2>&1; then
  log "Installing VS Code Remote-SSH extension"
  code --install-extension ms-vscode-remote.remote-ssh --force
else
  log "WARNING: 'code' CLI not on PATH yet. In VS Code, run 'Shell Command: Install code command in PATH' from the command palette, then re-run this script."
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/chezmoi-apply.sh
source "${SCRIPT_DIR}/lib/chezmoi-apply.sh"
apply_dotfiles personal "$REPO_ROOT"

# Split DNS for the lab's internal zone. Useful here only while this machine is
# on the home LAN, where the server routes the lab for it — the mesh VPN does
# not carry those routes. Off the LAN the entry is harmless but dead, which is
# what the short timeout in the lib is for.
# shellcheck source=lib/lab-dns.sh
source "${SCRIPT_DIR}/lib/lab-dns.sh"
install_lab_resolver

log "Done. See docs/client-personal-setup.md for the remaining manual steps (tailscale up, etc.)."
