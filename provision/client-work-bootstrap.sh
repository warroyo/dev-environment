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

FORMULAE=(mosh chezmoi)
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

log "Configuring VS Code to never auto-install the Claude Code IDE extension"
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
mkdir -p "$(dirname "$VSCODE_SETTINGS")"
[ -f "$VSCODE_SETTINGS" ] || echo '{}' >"$VSCODE_SETTINGS"

if command -v python3 >/dev/null 2>&1; then
  if ! grep -q 'claude-code.autoInstallIdeExtension' "$VSCODE_SETTINGS" 2>/dev/null; then
    tmp="$(mktemp)"
    python3 - "$VSCODE_SETTINGS" "$tmp" <<'PYEOF'
import json, sys
path, out = sys.argv[1], sys.argv[2]
with open(path) as f:
    raw = f.read().strip()
data = json.loads(raw) if raw else {}
data["claude-code.autoInstallIdeExtension"] = False
with open(out, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    mv "$tmp" "$VSCODE_SETTINGS"
    log "Set claude-code.autoInstallIdeExtension=false"
  else
    log "VS Code already configured to skip Claude Code auto-install"
  fi
else
  log "WARNING: python3 not found — manually add \"claude-code.autoInstallIdeExtension\": false to:"
  log "  ${VSCODE_SETTINGS}"
fi

log "Applying chezmoi dotfiles (Claude-specific files are excluded on this host by dotfiles/.chezmoiignore.tmpl)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
chezmoi init --apply --source="${REPO_ROOT}/dotfiles"

log "Done. See docs/client-work-setup.md for the OpenVPN import and other manual steps."
