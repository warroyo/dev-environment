#!/usr/bin/env bash
#
# The local-model half of the agent stack on the server, on its own: the
# LiteLLM gateway, then Hermes Agent with its Docker sandbox (docs/local-ai.md).
#
#   ./provision/local-ai-setup.sh
#
# server-bootstrap.sh runs the same steps; this exists so a change to them can
# be applied without re-running the whole bootstrap. Idempotent: re-run it to
# pick up a new model in ansible/group_vars/inference.yml, or after bumping the
# LiteLLM image pin in lib/litellm.sh.
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your own user, not root: the stack and its keys belong to you." >&2
  exit 1
fi
SUDO="sudo"

# shellcheck source=lib/litellm.sh
source "${SCRIPT_DIR}/lib/litellm.sh"
# shellcheck source=lib/hermes.sh
source "${SCRIPT_DIR}/lib/hermes.sh"

log "Installing the LiteLLM gateway"
install_litellm

log "Installing Hermes Agent"
ensure_hermes
install_hermes_sandbox_net
configure_hermes

log "Done. Check with:"
log "  curl -s -H \"Authorization: Bearer \$(cat ~/.secrets/litellm-scripts.key)\" http://127.0.0.1:4000/v1/models | jq -r '.data[].id'"
log "  hermes chat --oneshot -q 'Say OK'"
