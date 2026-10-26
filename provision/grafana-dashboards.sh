#!/usr/bin/env bash
#
# Pushes the lab's Grafana Cloud dashboards (grafana/dashboards/*.json) into
# the "Lab" folder (docs/lab-metrics.md). Needs no sudo, so it is separate
# from metrics-setup.sh; run it after changing a dashboard file.
#
#   ./provision/grafana-dashboards.sh
#
# Needs ~/.secrets/grafana/dashboards.env (GRAFANA_URL, GRAFANA_SA_TOKEN).
set -euo pipefail

log() { printf '%s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/grafana.sh
source "${SCRIPT_DIR}/lib/grafana.sh"

install_grafana_dashboards "${SCRIPT_DIR}/../grafana/dashboards"
