#!/usr/bin/env bash
#
# The Spanish tutor on the server, on its own (docs/spanish-tutor.md).
#
#   ./provision/spanish-tutor-setup.sh
#   SPANISH_TUTOR_REF=<commit> ./provision/spanish-tutor-setup.sh   # a different build
#
# server-bootstrap.sh runs the same step; this exists so a new tutor commit
# can be deployed without re-running the whole bootstrap. Idempotent: bump
# SPANISH_TUTOR_REF in lib/spanish-tutor.sh after pushing to the tutor repo and
# re-run it. Needs LiteLLM (local-ai-setup.sh) first, and GitHub access for the
# private repo (`gh auth login`).
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your own user, not root: the service and its keys belong to you." >&2
  exit 1
fi
SUDO="sudo"

# shellcheck source=lib/spanish-tutor.sh
source "${SCRIPT_DIR}/lib/spanish-tutor.sh"

log "Installing the Spanish tutor"
install_spanish_tutor

log "Done. Check with:"
log "  curl -s http://127.0.0.1:8096/healthz"
log "  systemctl status spanish-tutor --no-pager"
log "  tailscale serve status"
