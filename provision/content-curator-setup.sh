#!/usr/bin/env bash
#
# The content curator on the server, on its own (docs/content-curator.md).
#
#   ./provision/content-curator-setup.sh
#   CURATOR_REF=<commit> ./provision/content-curator-setup.sh   # pin a build
#
# server-bootstrap.sh runs the same step; this exists so a new curator commit
# can be deployed without re-running the whole bootstrap. Idempotent: re-run it
# after pushing to the curator repo. Needs LiteLLM (local-ai-setup.sh) first.
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your own user, not root: the service and its keys belong to you." >&2
  exit 1
fi
SUDO="sudo"

# shellcheck source=lib/content-curator.sh
source "${SCRIPT_DIR}/lib/content-curator.sh"

log "Installing the content curator"
install_content_curator

log "Done. Check with:"
log "  curl -s http://127.0.0.1:8090/api/status | jq '.last_runs[:3]'"
log "  systemctl status content-curator --no-pager"
