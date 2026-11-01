#!/usr/bin/env bash
# The content curator (github.com/warroyo/content-curator): a long-running
# service that collects feeds and podcasts, has local-qwen score them
# overnight, and publishes the picks to Raindrop.io (docs/content-curator.md).
#
#   install_content_curator   pulls the pinned image, writes the compose file,
#                             app.yaml, the env file and the systemd units,
#                             renders the config from the vault, and
#                             (re)starts the service
#
# Expects the caller to have defined `log` and `$SUDO`, same as lib/litellm.sh,
# and LiteLLM to be installed first: the curator's key comes from it.
#
# SHAPE
#
# The curator repo publishes its image to GHCR from CI; this lib only installs
# it, pinned by tag AND digest like LiteLLM's. One container, host networking
# (it reaches LiteLLM on 127.0.0.1:4000), its API and /metrics on
# 127.0.0.1:8090. restart: unless-stopped covers crashes; content-curator.service
# owns boot and shutdown.
#
#   ~/.local/share/content-curator/compose.yaml           generated
#   ~/.local/share/content-curator/config/app.yaml        generated: schedule, publishing
#   ~/.local/share/content-curator/config/sources.yaml    rendered from the vault
#   ~/.local/share/content-curator/config/interests.yaml  rendered from the vault
#   ~/.local/share/content-curator/render-config          the renderer, generated
#   ~/.local/share/content-curator/data/                  SQLite database and reports
#   ~/.secrets/content-curator/curator.env                generated: the two keys
#
# CONFIG FROM THE VAULT
#
# The curator reads plain YAML from /config and knows nothing about the vault.
# What to follow and what matters (sources, interests) is preference, not
# deployment, so it is written as two notes in the Obsidian vault, readable and
# editable there: notes/content-curator-sources.md and
# notes/content-curator-interests.md, the settings in fenced yaml blocks.
#
# render-config turns them into YAML: it joins each note's yaml blocks, checks
# the result by loading it with the curator image's own config code, and only
# then replaces the file in config/. A note that does not parse or validate
# leaves the last good file in place and fails the unit, so a bad edit never
# breaks a night's run. It runs at install, and nightly at 01:20 from
# content-curator-config.timer, right after a fast-forward-only pull of the
# vault, so an edit made on a Mac reaches the 01:30 run. The curator reads its
# config at the start of every job, so no restart is needed.
#
# SECRETS
#
#   ~/.secrets/litellm/content-curator.key   made by lib/litellm.sh
#   ~/.secrets/raindrop/token                Raindrop.io test token, by hand:
#                                            app.raindrop.io/settings/integrations,
#                                            create an app, copy "Test token"
#
# Without the Raindrop token the curator still runs, but publishing fails each
# night and the job is marked failed.

# Bump to deploy a new curator build: the tag and digest are in the summary of
# the curator's "image" workflow run.
CURATOR_IMAGE="${CURATOR_IMAGE:-ghcr.io/warroyo/content-curator:sha-3b8e362@sha256:f793be6f57dea7aa4b139382654ff4dd41df7f1939640887959434fe90d6380b}"
CURATOR_DIR="${CURATOR_DIR:-$HOME/.local/share/content-curator}"
CURATOR_DATA="${CURATOR_DIR}/data"
CURATOR_SECRETS_DIR="${CURATOR_SECRETS_DIR:-$HOME/.secrets/content-curator}"
CURATOR_ENV="${CURATOR_SECRETS_DIR}/curator.env"
CURATOR_LLM_KEY_FILE="${CURATOR_LLM_KEY_FILE:-$HOME/.secrets/litellm/content-curator.key}"
CURATOR_RAINDROP_TOKEN_FILE="${CURATOR_RAINDROP_TOKEN_FILE:-$HOME/.secrets/raindrop/token}"
CURATOR_VAULT="${CURATOR_VAULT:-$HOME/second-brain}"
CURATOR_PORT=8090
CURATOR_URL="http://127.0.0.1:${CURATOR_PORT}"
# Schedule, in the curator's cron syntax. Weekdays by name: APScheduler counts
# 0 as Monday, and the curator rejects numbers.
CURATOR_TIMEZONE="${CURATOR_TIMEZONE:-America/Denver}"
CURATOR_RUN_CRON="${CURATOR_RUN_CRON:-30 1 * * *}"
CURATOR_DISCOVER_CRON="${CURATOR_DISCOVER_CRON:-0 1 * * sun}"
# systemd calendar time for rendering the config, before the run above.
CURATOR_CONFIG_AT="${CURATOR_CONFIG_AT:-*-*-* 01:20:00}"
# Publishing to Raindrop: on, into these collections (created on first use).
CURATOR_PUBLISH="${CURATOR_PUBLISH:-true}"
CURATOR_PICKS_COLLECTION="${CURATOR_PICKS_COLLECTION:-AI picks}"
CURATOR_INBOX_COLLECTION="${CURATOR_INBOX_COLLECTION:-To curate}"
# Where the curator ran before this lib existed, started by hand from a working copy.
CURATOR_OLD_CHECKOUT="${CURATOR_OLD_CHECKOUT:-$HOME/workspace/content-curator}"

# install_content_curator
#
# Idempotent. Rewrites the generated files every run, restarts the service only
# when the image, the compose file, app.yaml, the env file or the unit changed.
# Returns non-zero if it does not come up.
install_content_curator() {
  local changed=0 f rc gen path mode

  if ! command -v docker >/dev/null 2>&1; then
    log "  WARNING: docker is not installed — skipping the content curator."
    return 1
  fi
  if [ ! -s "$CURATOR_LLM_KEY_FILE" ]; then
    log "  WARNING: ${CURATOR_LLM_KEY_FILE} is missing — install LiteLLM first. Skipping the curator."
    return 1
  fi
  if [ ! -s "$CURATOR_RAINDROP_TOKEN_FILE" ]; then
    log "  WARNING: ${CURATOR_RAINDROP_TOKEN_FILE} is missing — the curator will run, but publishing"
    log "           to Raindrop will fail until it exists (see the header of lib/content-curator.sh)."
  fi

  mkdir -p "$CURATOR_DIR/config" "$CURATOR_DATA" "$CURATOR_SECRETS_DIR"
  chmod 700 "$HOME/.secrets" "$CURATOR_SECRETS_DIR"

  if ! docker image inspect "$CURATOR_IMAGE" >/dev/null 2>&1; then
    log "  pulling ${CURATOR_IMAGE%@*}"
    if ! docker pull -q "$CURATOR_IMAGE" >/dev/null; then
      log "  WARNING: could not pull ${CURATOR_IMAGE}."
      return 1
    fi
    changed=1
  fi

  for f in compose:compose.yaml:644 app:config/app.yaml:644 renderer:render-config:755; do
    IFS=: read -r gen path mode <<<"$f"
    rc=0
    _curator_write_if_changed "${CURATOR_DIR}/${path}" "_curator_${gen}" "$mode" || rc=$?
    case $rc in
      0) [ "$gen" = renderer ] || changed=1 ;;
      1) ;;
      *) log "  WARNING: could not generate ${path} — skipping the curator."; return 1 ;;
    esac
  done
  rc=0
  _curator_write_if_changed "$CURATOR_ENV" _curator_env 600 || rc=$?
  [ "$rc" -eq 0 ] && changed=1

  log "  rendering sources and interests from ${CURATOR_VAULT}/notes"
  if ! "${CURATOR_DIR}/render-config"; then
    if [ ! -s "${CURATOR_DIR}/config/sources.yaml" ] || [ ! -s "${CURATOR_DIR}/config/interests.yaml" ]; then
      log "  WARNING: no valid curator config yet — fix the vault notes and re-run. Skipping the curator."
      return 1
    fi
    log "  WARNING: the vault notes did not validate — keeping the last good config."
  fi

  _curator_migrate_hand_started

  _curator_install_unit content-curator.service "$(_curator_service_unit)" && changed=1
  _curator_install_unit content-curator-config.service "$(_curator_config_unit)" || true
  _curator_install_unit content-curator-config.timer "$(_curator_config_timer)" || true
  $SUDO systemctl enable content-curator.service >/dev/null 2>&1 || true
  $SUDO systemctl enable --now content-curator-config.timer >/dev/null 2>&1 || true

  if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet content-curator.service; then
    log "  (re)starting content-curator.service"
    # restart, not start: RemainAfterExit keeps a oneshot "active" after the
    # container is gone, and start would then do nothing.
    if ! $SUDO systemctl restart content-curator.service; then
      log "  WARNING: content-curator.service failed — check 'journalctl -u content-curator' and"
      log "           'docker logs content-curator-curator-1'."
      return 1
    fi
  fi

  if ! _curator_wait_ready; then
    log "  WARNING: the curator did not answer on ${CURATOR_URL}/healthz."
    return 1
  fi
  log "  content curator ready on ${CURATOR_URL} (${CURATOR_IMAGE%@*})"
  _curator_prune_images
}

# _curator_write_if_changed <path> <generator> <mode>
#
# Same contract as lib/litellm.sh: 0 changed, 1 unchanged, 2 generator failed.
_curator_write_if_changed() {
  local path="$1" gen="$2" mode="$3" tmp
  tmp="$(umask 077; mktemp)"
  if ! "$gen" >"$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  if cmp -s "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp"
  mv "$tmp" "$path"
  return 0
}

# _curator_install_unit <name> <content>
#
# Returns 0 if the unit changed (and reloads systemd), 1 if it was current.
_curator_install_unit() {
  local name="$1" path="/etc/systemd/system/$1" tmp
  tmp="$(mktemp)"
  printf '%s\n' "$2" >"$tmp"
  if $SUDO cmp -s "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  $SUDO cp "$tmp" "$path"
  $SUDO chmod 644 "$path"
  $SUDO systemctl daemon-reload
  rm -f "$tmp"
  log "  wrote ${name}"
  return 0
}

_curator_compose() {
  cat <<EOF
# Managed by dev-environment/provision/lib/content-curator.sh — do not edit by hand.
name: content-curator

services:
  curator:
    image: ${CURATOR_IMAGE}
    command: ["serve"]
    user: "$(id -u):$(id -g)"
    network_mode: host
    env_file: ${CURATOR_ENV}
    environment:
      CURATOR_DATA_DIR: /data
      CURATOR_CONFIG_DIR: /config
      CURATOR_API_HOST: 127.0.0.1
      CURATOR_API_PORT: "${CURATOR_PORT}"
    volumes:
      - ./data:/data
      - ./config:/config:ro
    restart: unless-stopped
    init: true
    stop_grace_period: 40s
    healthcheck:
      test: ["CMD", "curator-healthcheck"]
      interval: 5m
      timeout: 10s
      start_period: 30s
      start_interval: 5s
      retries: 2
    # Low CPU weight: under contention the agents on this box win. One core at most.
    cpu_shares: 256
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
EOF
}

_curator_app() {
  cat <<EOF
# Managed by dev-environment/provision/lib/content-curator.sh — do not edit by hand.
# sources.yaml and interests.yaml next to it are rendered from the vault by render-config.
schedule:
  timezone: ${CURATOR_TIMEZONE}
  misfire_grace_seconds: 3600
  jobs:
    - {job: run, cron: "${CURATOR_RUN_CRON}"}
    - {job: discover, cron: "${CURATOR_DISCOVER_CRON}"}
publish:
  enabled: ${CURATOR_PUBLISH}
  collection: ${CURATOR_PICKS_COLLECTION}
  inbox_collection: ${CURATOR_INBOX_COLLECTION}
EOF
}

_curator_env() {
  local token=""
  [ -s "$CURATOR_RAINDROP_TOKEN_FILE" ] && token="$(tr -d '[:space:]' <"$CURATOR_RAINDROP_TOKEN_FILE")"
  cat <<EOF
# Generated by dev-environment/provision/lib/content-curator.sh — do not edit by hand.
CURATOR_LLM_API_KEY=$(tr -d '[:space:]' <"$CURATOR_LLM_KEY_FILE")
CURATOR_RAINDROP_TOKEN=${token}
EOF
}

# _curator_renderer
#
# The script behind content-curator-config.service and the install step. The
# notes' prose is ignored; only ```yaml blocks count, joined in order.
_curator_renderer() {
  cat <<EOF
#!/usr/bin/env bash
# Generated by dev-environment/provision/lib/content-curator.sh — do not edit by hand.
# Renders the curator's sources and interests from the vault notes into
# ${CURATOR_DIR}/config, after checking them with the curator's own config code.
set -euo pipefail

vault="${CURATOR_VAULT}/notes"
config="${CURATOR_DIR}/config"
image="${CURATOR_IMAGE}"
EOF
  cat <<'RENDER'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for name in sources interests; do
  python3 - "${vault}/content-curator-${name}.md" "${tmp}/${name}.yaml" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
blocks = re.findall(r"^```ya?ml[ \t]*\n(.*?)^```", text, flags=re.MULTILINE | re.DOTALL)
if not blocks:
    sys.exit(f"{src}: no ```yaml block")
with open(dst, "w", encoding="utf-8") as f:
    f.write(f"# Rendered from {src}. Edit the note, not this file.\n")
    f.write("\n".join(blocks))
PY
done
cp "${config}/app.yaml" "${tmp}/app.yaml"

# Validate with the image that will read it.
docker run --rm --network none --user "$(id -u):$(id -g)" -v "${tmp}:/config:ro" \
  --entrypoint python "$image" -c '
from pathlib import Path
from content_curator.config import load_app_config, load_interests, load_sources
p = Path("/config")
load_app_config(p)
print(f"valid: {len(load_sources(p))} sources, {len(load_interests(p).groups)} interest groups")'

for name in sources interests; do
  if ! cmp -s "${tmp}/${name}.yaml" "${config}/${name}.yaml"; then
    install -m 644 "${tmp}/${name}.yaml" "${config}/${name}.yaml"
    echo "updated ${config}/${name}.yaml"
  fi
done
RENDER
}

# Pull first, fast-forward only and allowed to fail ("-"): a vault with local
# commits that diverge, or an edit to a file the pull would change, makes git
# refuse, and the render uses what is on disk.
_curator_config_unit() {
  cat <<EOF
# Managed by dev-environment/provision/lib/content-curator.sh — do not edit by hand.
[Unit]
Description=Render the content curator's config from the vault
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=${USER}
Environment=GIT_TERMINAL_PROMPT=0
ExecStartPre=-/usr/bin/git -C ${CURATOR_VAULT} pull --ff-only --quiet
ExecStart=${CURATOR_DIR}/render-config
EOF
}

_curator_config_timer() {
  cat <<EOF
# Managed by dev-environment/provision/lib/content-curator.sh — do not edit by hand.
[Unit]
Description=Render the content curator's config from the vault before the nightly run

[Timer]
OnCalendar=${CURATOR_CONFIG_AT}
Persistent=false

[Install]
WantedBy=timers.target
EOF
}

# _curator_migrate_hand_started
#
# Before this lib, the curator ran from a working copy with `make up`, as the
# same compose project. Remove that container and copy its data across once, so
# the scores, published mappings and inbox state carry over. The old data
# directory is left in place, for you to delete.
_curator_migrate_hand_started() {
  local old_dir
  old_dir="$(docker ps -a --filter label=com.docker.compose.project=content-curator \
    --format '{{.Label "com.docker.compose.project.working_dir"}}' | head -n1)"
  if [ -n "$old_dir" ] && [ "$old_dir" != "$CURATOR_DIR" ]; then
    log "  removing the hand-started curator container (from ${old_dir})"
    docker ps -aq --filter label=com.docker.compose.project=content-curator | xargs -r docker rm -f >/dev/null
  fi
  if [ ! -e "${CURATOR_DATA}/curator.db" ] && [ -s "${CURATOR_OLD_CHECKOUT}/data/curator.db" ]; then
    log "  copying ${CURATOR_OLD_CHECKOUT}/data to ${CURATOR_DATA}"
    cp -a "${CURATOR_OLD_CHECKOUT}/data/." "${CURATOR_DATA}/"
  fi
}

_curator_wait_ready() {
  local _
  for _ in $(seq 1 30); do
    if curl -fsS -m 5 "${CURATOR_URL}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# _curator_prune_images
#
# Each bump pulls a new image (about 200 MB). Remove older sha- tags.
_curator_prune_images() {
  local repo="${CURATOR_IMAGE%%:*}" current tag
  current="${CURATOR_IMAGE#*:}"
  current="${current%%@*}"
  docker image ls "$repo" --format '{{.Tag}}' | while read -r tag; do
    case "$tag" in
      sha-*) [ "$tag" = "$current" ] && continue ;;
      *) continue ;;
    esac
    docker image rm "${repo}:${tag}" >/dev/null 2>&1 && log "  removed old image ${repo}:${tag}"
  done
  return 0
}
