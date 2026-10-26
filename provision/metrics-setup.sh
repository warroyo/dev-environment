#!/usr/bin/env bash
#
# The lab metrics shipper on the server, on its own: Grafana Alloy, scraping
# this box and the lab targets and sending to Grafana Cloud
# (docs/lab-metrics.md).
#
#   ./provision/metrics-setup.sh
#
# server-bootstrap.sh runs the same step; this exists so a change to the
# config or a version bump in lib/alloy.sh can be applied without re-running
# the whole bootstrap. Idempotent. Needs ~/.secrets/grafana-cloud.
#
# The lab targets' side (node_exporter, the engine metrics) is Ansible:
#   ansible/play inference --tags metrics
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your own user, not root: the credentials are read from your ~/.secrets." >&2
  exit 1
fi
SUDO="sudo"

# shellcheck source=lib/alloy.sh
source "${SCRIPT_DIR}/lib/alloy.sh"

log "Installing Grafana Alloy"
install_alloy

log "Done. Check with:"
log "  curl -s http://${ALLOY_LISTEN}/-/ready"
log "  journalctl -u alloy -n 50 --no-pager | grep -i error"
log "  then in Grafana Cloud Explore: up{job=~\"node|llama-swap\"}"
