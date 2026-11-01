#!/usr/bin/env bash
# Local Headlamp for testing the Tanzu 11 plugin. No cluster resources are installed.
# Usage: bash provision/headlamp-dev.sh [start|stop|status|logs]
# Rebuild the plugin in its repo; refresh the browser to load the new bundle.
set -euo pipefail

HEADLAMP_IMAGE="${HEADLAMP_IMAGE:-ghcr.io/headlamp-k8s/headlamp:v0.46.0}"
HEADLAMP_CONTAINER="headlamp-tanzu-dev"
HEADLAMP_PLUGIN_REPO="${HEADLAMP_PLUGIN_REPO:-$HOME/workspace/headlamp-tanzu-apps}"
HEADLAMP_KUBECONFIG="${HEADLAMP_KUBECONFIG:-$HOME/.kube/headlamp-dev.kubeconfig}"
HEADLAMP_PORT="${HEADLAMP_PORT:-4466}"
HEADLAMP_LISTEN_ADDR="${HEADLAMP_LISTEN_ADDR:-0.0.0.0}"

case "${1:-start}" in
  start)
    test -f "$HEADLAMP_PLUGIN_REPO/dist/main.js"
    test -f "$HEADLAMP_KUBECONFIG"
    cp "$HEADLAMP_PLUGIN_REPO/package.json" "$HEADLAMP_PLUGIN_REPO/dist/package.json"
    if [[ "$(docker inspect --format '{{.State.Status}}' "$HEADLAMP_CONTAINER" 2>/dev/null || true)" == created ]]; then
      docker rm "$HEADLAMP_CONTAINER" >/dev/null
    fi
    if docker container inspect "$HEADLAMP_CONTAINER" >/dev/null 2>&1; then
      docker start "$HEADLAMP_CONTAINER" >/dev/null
    else
      docker run -d --name "$HEADLAMP_CONTAINER" \
        --network host \
        --user "$(id -u):$(id -g)" \
        --read-only --tmpfs /tmp:rw,nosuid,nodev,size=64m \
        --cap-drop ALL --security-opt no-new-privileges \
        -e KUBECONFIG=/tmp/kubeconfig -e HOME=/tmp \
        --mount "type=bind,source=$HEADLAMP_KUBECONFIG,target=/tmp/kubeconfig,readonly" \
        --mount "type=bind,source=$HEADLAMP_PLUGIN_REPO/dist,target=/headlamp/plugins/headlamp-tanzu-apps,readonly" \
        "$HEADLAMP_IMAGE" \
        -html-static-dir=/headlamp/frontend -plugins-dir=/headlamp/plugins \
        "-listen-addr=$HEADLAMP_LISTEN_ADDR" "-port=$HEADLAMP_PORT"
    fi
    printf 'Headlamp port: %s (container: %s)\n' "$HEADLAMP_PORT" "$HEADLAMP_CONTAINER"
    ;;
  stop) docker stop "$HEADLAMP_CONTAINER" ;;
  status) docker ps -a --filter "name=^/$HEADLAMP_CONTAINER$" ;;
  logs) docker logs --tail 80 "$HEADLAMP_CONTAINER" ;;
  *) printf 'Usage: %s [start|stop|status|logs]\n' "$0" >&2; exit 2 ;;
esac
