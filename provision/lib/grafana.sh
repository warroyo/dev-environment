#!/usr/bin/env bash
# Grafana Cloud dashboards from grafana/dashboards/*.json (docs/lab-metrics.md).
#
#   install_grafana_dashboards   pushes every dashboard in grafana/dashboards
#                                into the "Lab" folder, overwriting what is there
#
# Expects the caller to have defined `log`. Needs no sudo.
#
# The JSON files are the source of truth. An edit made in the Grafana UI is
# overwritten by the next push, so change the file (or export the edited
# dashboard over it) and push again.
#
# SECRETS
#
# ~/.secrets/grafana/dashboards.env, written by hand once:
#
#   GRAFANA_URL=https://<stack>.grafana.net
#   GRAFANA_SA_TOKEN=glsa_...
#
# The token belongs to a service account with the Editor role
# (Administration > Users and access > Service accounts). It is separate from
# Alloy's metrics:write token on purpose: that one only writes samples, this
# one can change dashboards.
#
# A subdirectory, and no `export`: every interactive shell sources each
# top-level file in ~/.secrets (dotfiles 55_secrets.sh), and nothing but this
# push needs an Editor token.

GRAFANA_SECRETS="${GRAFANA_SECRETS:-$HOME/.secrets/grafana/dashboards.env}"
GRAFANA_FOLDER_UID="${GRAFANA_FOLDER_UID:-lab}"
GRAFANA_FOLDER_TITLE="${GRAFANA_FOLDER_TITLE:-Lab}"

# install_grafana_dashboards <dashboards dir>
install_grafana_dashboards() {
  local dir="$1" url token f failed=0

  if [ ! -r "$GRAFANA_SECRETS" ]; then
    log "  WARNING: ${GRAFANA_SECRETS} is missing — skipping the dashboards."
    log "           Create it with GRAFANA_URL and GRAFANA_SA_TOKEN; see docs/lab-metrics.md."
    return 1
  fi
  # shellcheck disable=SC1090
  url="$(. "$GRAFANA_SECRETS" && printf '%s' "${GRAFANA_URL:-}")"
  # shellcheck disable=SC1090
  token="$(. "$GRAFANA_SECRETS" && printf '%s' "${GRAFANA_SA_TOKEN:-}")"
  url="${url%/}"
  if [ -z "$url" ] || [ -z "$token" ]; then
    log "  WARNING: ${GRAFANA_SECRETS} needs GRAFANA_URL and GRAFANA_SA_TOKEN — skipping the dashboards."
    return 1
  fi

  # The token goes in a header file rather than on the command line, so it
  # never shows in `ps`.
  local hdr
  hdr="$(mktemp)"
  chmod 600 "$hdr"
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$hdr"

  if ! curl -fsS -m 20 -K "$hdr" "${url}/api/folders/${GRAFANA_FOLDER_UID}" >/dev/null 2>&1; then
    if curl -fsS -m 20 -K "$hdr" -X POST -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg u "$GRAFANA_FOLDER_UID" --arg t "$GRAFANA_FOLDER_TITLE" '{uid: $u, title: $t}')" \
         "${url}/api/folders" >/dev/null; then
      log "  created Grafana folder ${GRAFANA_FOLDER_TITLE}"
    else
      log "  WARNING: could not create Grafana folder ${GRAFANA_FOLDER_TITLE}"
      rm -f "$hdr"
      return 1
    fi
  fi

  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    local out
    if out="$(jq -c --arg folder "$GRAFANA_FOLDER_UID" \
                '{dashboard: (. | del(.id) | .version = null), folderUid: $folder, overwrite: true,
                  message: "pushed by dev-environment provision/lib/grafana.sh"}' "$f" |
              curl -fsS -m 30 -K "$hdr" -X POST -H 'Content-Type: application/json' \
                --data-binary @- "${url}/api/dashboards/db")"; then
      log "  dashboard $(basename "$f") pushed: ${url}$(printf '%s' "$out" | jq -r '.url')"
    else
      log "  WARNING: could not push dashboard $(basename "$f")"
      failed=1
    fi
  done
  rm -f "$hdr"
  return "$failed"
}
