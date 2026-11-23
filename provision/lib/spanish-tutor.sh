#!/usr/bin/env bash
# The Spanish tutor (github.com/warroyo/spanish-tutor): the memory behind a
# 12-week Mexican Spanish speaking plan. A web app (curriculum week, session
# prompts, report ingest, error log, FSRS card review, typed drills) that Will
# reaches from his phone over the tailnet (docs/spanish-tutor.md).
#
#   install_spanish_tutor   clones the private repo at a pinned ref, builds the
#                           image on this host, writes the compose file, the
#                           env file and the systemd units, (re)starts the
#                           service and publishes it with `tailscale serve`
#
# Expects the caller to have defined `log` and `$SUDO`, same as
# lib/content-curator.sh, and LiteLLM to be installed first: the tutor's key
# comes from it.
#
# SHAPE
#
# Unlike the curator, the image is never pulled from a registry: the repo is
# private, and building here avoids a registry token. The ref below is a commit
# (or tag) of the app repo; the image is tagged with that commit's short hash,
# so a new ref is a new image and a restart. One container, host networking (it
# reaches LiteLLM on 127.0.0.1:4000), bound to 127.0.0.1:8096.
# restart: unless-stopped covers crashes; spanish-tutor.service owns boot and
# shutdown.
#
#   ~/.local/share/spanish-tutor/src/                clone of the app repo, at the ref
#   ~/.local/share/spanish-tutor/compose.yaml        generated
#   ~/.local/share/spanish-tutor/data/               tutor.db, recordings/, backups/
#   ~/.local/share/spanish-tutor/backup              the backup script, generated
#   ~/.secrets/spanish-tutor/tutor.env               generated: LiteLLM key and settings
#   ~/.secrets/litellm/spanish-tutor.key             made by lib/litellm.sh (LITELLM_CLIENTS)
#
# The curriculum and the prompt templates (config/) are read from the clone,
# read-only, so they always match the pinned ref.
#
# TAILNET
#
# `tailscale serve --bg --https=8443 http://127.0.0.1:8096` gives
# https://<this host>.<tailnet>.ts.net:8443/ to tailnet members only. This is the
# lab's first `tailscale serve`, so this lib owns it. Never `tailscale funnel`:
# the app has no login of its own, the tailnet is the only access control.
#
# TIME ZONE
#
# TZ goes into the env file so session dates, the daily new-card cap and the
# 02:30 drill check use local time, not UTC. It is read from the host
# (timedatectl) on every run rather than hard-coded: re-running after the box's
# zone changes fixes the app, and the file never disagrees with `date`.
# TUTOR_TZ overrides it; America/Denver is the fallback when timedatectl says
# nothing. The python:alpine image has no zoneinfo database, so the compose file
# mounts the host's /usr/share/zoneinfo read-only; without it TZ is silently
# ignored and the app runs in UTC.
#
# BACKUPS
#
# spanish-tutor-backup.timer runs `backup` nightly. It asks the running
# container (docker compose exec, or a throwaway run if it is down) for a
# SQLite online backup with python's sqlite3 backup API, since the host has no
# sqlite3 binary and a plain file copy of a live database can be torn. The copy
# is integrity-checked, kept as data/backups/tutor-<stamp>.db (newest 14), and
# new recordings are copied across to data/backups/recordings/ (never
# overwritten, never deleted: a recording removed in the app stays in the
# backup). The backups live on the same disk as the data; they cover a bad
# migration or a deleted row, not a dead disk.

# Bump to deploy a new build: a commit hash of warroyo/spanish-tutor, written
# out in full. Then re-run provision/spanish-tutor-setup.sh.
# (main as of 2026-11-22, complete through M7.)
SPANISH_TUTOR_REF="${SPANISH_TUTOR_REF:-844b7a262fb0283e6d7fd9cdd0dee0453a2eb03d}"
SPANISH_TUTOR_REPO="${SPANISH_TUTOR_REPO:-warroyo/spanish-tutor}"
SPANISH_TUTOR_REPO_URL="${SPANISH_TUTOR_REPO_URL:-https://github.com/${SPANISH_TUTOR_REPO}.git}"
SPANISH_TUTOR_DIR="${SPANISH_TUTOR_DIR:-$HOME/.local/share/spanish-tutor}"
SPANISH_TUTOR_SRC="${SPANISH_TUTOR_DIR}/src"
SPANISH_TUTOR_DATA="${SPANISH_TUTOR_DIR}/data"
SPANISH_TUTOR_SECRETS_DIR="${SPANISH_TUTOR_SECRETS_DIR:-$HOME/.secrets/spanish-tutor}"
SPANISH_TUTOR_ENV="${SPANISH_TUTOR_SECRETS_DIR}/tutor.env"
SPANISH_TUTOR_LLM_KEY_FILE="${SPANISH_TUTOR_LLM_KEY_FILE:-$HOME/.secrets/litellm/spanish-tutor.key}"
SPANISH_TUTOR_LLM_URL="${SPANISH_TUTOR_LLM_URL:-http://127.0.0.1:4000/v1}"
SPANISH_TUTOR_PORT=8096
SPANISH_TUTOR_HTTPS_PORT=8443
SPANISH_TUTOR_URL="http://127.0.0.1:${SPANISH_TUTOR_PORT}"
# Built here and never pulled; the name only has to be unique. pull_policy:
# never in the compose file makes a missing image an error, not a registry pull.
SPANISH_TUTOR_IMAGE_REPO="${SPANISH_TUTOR_IMAGE_REPO:-spanish-tutor}"
# Settings written to the env file (docs/reference/configuration.md in the app repo).
SPANISH_TUTOR_START_DATE="${SPANISH_TUTOR_START_DATE:-2026-11-24}"
SPANISH_TUTOR_MODEL="${SPANISH_TUTOR_MODEL:-local-qwen}"
SPANISH_TUTOR_WEEK_PLAN="${SPANISH_TUTOR_WEEK_PLAN:-tue=speak,wed=speak,thu=silent,fri=speak,sat=exam,sun=silent,mon=speak}"
SPANISH_TUTOR_NEW_CARDS="${SPANISH_TUTOR_NEW_CARDS:-10}"
SPANISH_TUTOR_DRILL_SCHEDULE="${SPANISH_TUTOR_DRILL_SCHEDULE:-02:30}"
# Nightly backup, systemd calendar time (host local time), and how many to keep.
SPANISH_TUTOR_BACKUP_AT="${SPANISH_TUTOR_BACKUP_AT:-*-*-* 04:10:00}"
SPANISH_TUTOR_BACKUP_KEEP="${SPANISH_TUTOR_BACKUP_KEEP:-14}"

# Set by install_spanish_tutor once the ref is resolved and the image built.
SPANISH_TUTOR_IMAGE=""

# install_spanish_tutor
#
# Idempotent. Rewrites the generated files every run, rebuilds only when the
# image for the pinned commit is missing, restarts the service only when the
# image, the compose file, the env file or the unit changed. Returns non-zero
# if it does not come up.
install_spanish_tutor() {
  local changed=0 f rc gen path mode commit

  if ! command -v docker >/dev/null 2>&1; then
    log "  WARNING: docker is not installed — skipping the Spanish tutor."
    return 1
  fi
  if [ ! -s "$SPANISH_TUTOR_LLM_KEY_FILE" ]; then
    # The key is made by install_litellm for every client in LITELLM_CLIENTS.
    # server-bootstrap.sh has run it by now; the setup script alone may be
    # first on a box that predates this client.
    if ! declare -F install_litellm >/dev/null; then
      # shellcheck source=lib/litellm.sh
      source "$(dirname "${BASH_SOURCE[0]}")/litellm.sh"
    fi
    log "  no ${SPANISH_TUTOR_LLM_KEY_FILE} — running install_litellm to make it"
    install_litellm || true
  fi
  if [ ! -s "$SPANISH_TUTOR_LLM_KEY_FILE" ]; then
    log "  WARNING: ${SPANISH_TUTOR_LLM_KEY_FILE} is missing — install LiteLLM first. Skipping the Spanish tutor."
    return 1
  fi

  mkdir -p "$SPANISH_TUTOR_DIR" "$SPANISH_TUTOR_DATA" "$SPANISH_TUTOR_SECRETS_DIR"
  chmod 700 "$HOME/.secrets" "$SPANISH_TUTOR_SECRETS_DIR"

  commit="$(_tutor_checkout)" || return 1
  SPANISH_TUTOR_IMAGE="${SPANISH_TUTOR_IMAGE_REPO}:${commit:0:12}"

  if ! docker image inspect "$SPANISH_TUTOR_IMAGE" >/dev/null 2>&1; then
    log "  building ${SPANISH_TUTOR_IMAGE} from ${commit:0:12}"
    if ! TUTOR_TAG="${commit:0:12}" docker compose -p spanish-tutor-build \
        -f "${SPANISH_TUTOR_SRC}/compose.yaml" build tutor >/dev/null; then
      log "  WARNING: the image build failed."
      return 1
    fi
    # compose names it after the app repo's registry; give it the local name.
    docker tag "ghcr.io/warroyo/spanish-tutor:${commit:0:12}" "$SPANISH_TUTOR_IMAGE"
    docker image rm "ghcr.io/warroyo/spanish-tutor:${commit:0:12}" >/dev/null 2>&1 || true
    changed=1
  fi

  for f in compose:compose.yaml:644 backup:backup:755; do
    IFS=: read -r gen path mode <<<"$f"
    rc=0
    _tutor_write_if_changed "${SPANISH_TUTOR_DIR}/${path}" "_tutor_${gen}" "$mode" || rc=$?
    case $rc in
      0) [ "$gen" = backup ] || changed=1 ;;
      1) ;;
      *) log "  WARNING: could not generate ${path} — skipping the Spanish tutor."; return 1 ;;
    esac
  done
  rc=0
  _tutor_write_if_changed "$SPANISH_TUTOR_ENV" _tutor_env 600 || rc=$?
  [ "$rc" -eq 0 ] && changed=1

  rc=0
  _tutor_install_unit spanish-tutor.service "$(_tutor_service_unit)" || rc=$?
  case $rc in
    0) changed=1 ;;
    1) ;;
    *) return 1 ;;
  esac
  _tutor_install_unit spanish-tutor-backup.service "$(_tutor_backup_unit)" || true
  _tutor_install_unit spanish-tutor-backup.timer "$(_tutor_backup_timer)" || true
  $SUDO systemctl enable spanish-tutor.service >/dev/null 2>&1 || true
  $SUDO systemctl enable --now spanish-tutor-backup.timer >/dev/null 2>&1 || true

  if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet spanish-tutor.service; then
    log "  (re)starting spanish-tutor.service"
    # restart, not start: RemainAfterExit keeps a oneshot "active" after the
    # container is gone, and start would then do nothing.
    if ! $SUDO systemctl restart spanish-tutor.service; then
      log "  WARNING: spanish-tutor.service failed — check 'journalctl -u spanish-tutor' and"
      log "           'docker logs spanish-tutor-tutor-1'."
      return 1
    fi
  fi

  if ! _tutor_wait_ready; then
    log "  WARNING: the tutor did not answer on ${SPANISH_TUTOR_URL}/healthz."
    return 1
  fi
  log "  Spanish tutor ready on ${SPANISH_TUTOR_URL} (${SPANISH_TUTOR_IMAGE})"
  _tutor_tailscale_serve || true
  _tutor_prune_images
}

# _tutor_checkout
#
# Clones the app repo into ~/.local/share/spanish-tutor/src if needed, moves it
# to the pinned ref, and prints the commit hash. Same GitHub access as
# lib/repos.sh: gh first (a private repo, authenticated by the gh token), plain
# git otherwise. A full commit hash already in the clone needs no network.
_tutor_checkout() {
  local src="$SPANISH_TUTOR_SRC" commit
  local -x GIT_TERMINAL_PROMPT=0   # a private repo without credentials fails fast, no prompt

  if [ ! -d "$src/.git" ]; then
    if [ -e "$src" ]; then
      log "  WARNING: ${src} exists but is not a git repo — leaving it alone." >&2
      return 1
    fi
    log "  cloning ${SPANISH_TUTOR_REPO}" >&2
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh repo clone "$SPANISH_TUTOR_REPO" "$src" -- -q >&2 || rm -rf "$src"
    else
      git clone -q "$SPANISH_TUTOR_REPO_URL" "$src" >&2 || rm -rf "$src"
    fi
    if [ ! -d "$src/.git" ]; then
      log "  WARNING: could not clone ${SPANISH_TUTOR_REPO} — run 'gh auth login' and re-run." >&2
      return 1
    fi
  fi

  if ! { [[ "$SPANISH_TUTOR_REF" =~ ^[0-9a-f]{40}$ ]] \
         && git -C "$src" cat-file -e "${SPANISH_TUTOR_REF}^{commit}" 2>/dev/null; }; then
    log "  fetching ${SPANISH_TUTOR_REPO}" >&2
    git -C "$src" fetch -q --tags origin >&2 || log "  WARNING: git fetch failed; using what is cloned." >&2
  fi
  if ! git -C "$src" checkout -q -f --detach "$SPANISH_TUTOR_REF" >&2; then
    log "  WARNING: ref ${SPANISH_TUTOR_REF} is not in ${SPANISH_TUTOR_REPO}." >&2
    return 1
  fi
  git -C "$src" clean -qfd >&2 || true
  commit="$(git -C "$src" rev-parse HEAD)"
  printf '%s\n' "$commit"
}

# _tutor_tz
#
# TUTOR_TZ, else the host's zone from timedatectl, else America/Denver.
_tutor_tz() {
  local tz="${TUTOR_TZ:-}"
  [ -n "$tz" ] || tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  case "$tz" in
    ""|n/a) tz=America/Denver ;;
  esac
  printf '%s\n' "$tz"
}

# _tutor_write_if_changed <path> <generator> <mode>
#
# Same contract as lib/content-curator.sh: 0 changed, 1 unchanged, 2 generator failed.
_tutor_write_if_changed() {
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

# _tutor_install_unit <name> <content>
#
# Returns 0 if the unit changed (and reloads systemd), 1 if it was current,
# 2 if the content is empty (a generator failed).
_tutor_install_unit() {
  local name="$1" path="/etc/systemd/system/$1" tmp
  if [ -z "$2" ]; then
    log "  WARNING: generated an empty ${name} — not installing it."
    return 2
  fi
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

_tutor_compose() {
  cat <<EOF
# Managed by dev-environment/provision/lib/spanish-tutor.sh — do not edit by hand.
name: spanish-tutor

services:
  tutor:
    image: ${SPANISH_TUTOR_IMAGE}
    # Built on this host from the pinned ref; there is nothing to pull.
    pull_policy: never
    command: ["serve"]
    user: "$(id -u):$(id -g)"
    network_mode: host
    env_file: ${SPANISH_TUTOR_ENV}
    environment:
      TUTOR_DATA_DIR: /data
      TUTOR_CONFIG_DIR: /config
    volumes:
      - ./data:/data
      # Curriculum and prompt templates, from the clone at the pinned ref.
      - ./src/config:/config:ro
      # The image has no zoneinfo, so TZ would be ignored without it.
      - /usr/share/zoneinfo:/usr/share/zoneinfo:ro
    restart: unless-stopped
    init: true
    stop_grace_period: 20s
    healthcheck:
      test: ["CMD", "tutor-healthcheck"]
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

_tutor_env() {
  cat <<EOF
# Generated by dev-environment/provision/lib/spanish-tutor.sh — do not edit by hand.
LITELLM_BASE_URL=${SPANISH_TUTOR_LLM_URL}
LITELLM_API_KEY=$(tr -d '[:space:]' <"$SPANISH_TUTOR_LLM_KEY_FILE")
TUTOR_MODEL=${SPANISH_TUTOR_MODEL}
TUTOR_HOST=127.0.0.1
TUTOR_PORT=${SPANISH_TUTOR_PORT}
TZ=$(_tutor_tz)
TUTOR_START_DATE=${SPANISH_TUTOR_START_DATE}
TUTOR_WEEK_PLAN=${SPANISH_TUTOR_WEEK_PLAN}
TUTOR_NEW_CARDS_PER_DAY=${SPANISH_TUTOR_NEW_CARDS}
TUTOR_DRILL_SCHEDULE=${SPANISH_TUTOR_DRILL_SCHEDULE}
TUTOR_LOG_LEVEL=INFO
EOF
}

_tutor_service_unit() {
  cat <<EOF
# Managed by dev-environment/provision/lib/spanish-tutor.sh — do not edit by hand.
[Unit]
Description=Spanish tutor (127.0.0.1:${SPANISH_TUTOR_PORT}, tailnet HTTPS on :${SPANISH_TUTOR_HTTPS_PORT})
Requires=docker.service
After=docker.service network-online.target litellm.service
Wants=network-online.target litellm.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=${USER}
WorkingDirectory=${SPANISH_TUTOR_DIR}
# --wait returns once the healthcheck passes, so "active" means the app answers.
ExecStart=/usr/bin/docker compose up -d --wait --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
}

_tutor_backup_unit() {
  cat <<EOF
# Managed by dev-environment/provision/lib/spanish-tutor.sh — do not edit by hand.
[Unit]
Description=Back up the Spanish tutor's database and recordings
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
User=${USER}
WorkingDirectory=${SPANISH_TUTOR_DIR}
ExecStart=${SPANISH_TUTOR_DIR}/backup
EOF
}

_tutor_backup_timer() {
  cat <<EOF
# Managed by dev-environment/provision/lib/spanish-tutor.sh — do not edit by hand.
[Unit]
Description=Nightly backup of the Spanish tutor

[Timer]
OnCalendar=${SPANISH_TUTOR_BACKUP_AT}
# A box that was off at 04:10 takes the backup when it comes back.
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# _tutor_backup
#
# The script behind spanish-tutor-backup.service. See BACKUPS in the header.
_tutor_backup() {
  cat <<EOF
#!/usr/bin/env bash
# Generated by dev-environment/provision/lib/spanish-tutor.sh — do not edit by hand.
# Online SQLite backup of the Spanish tutor, then a copy of new recordings.
set -euo pipefail

dir="${SPANISH_TUTOR_DIR}"
keep=${SPANISH_TUTOR_BACKUP_KEEP}
EOF
  cat <<'BACKUP'
data="${dir}/data"
out="${data}/backups"
mkdir -p "${out}/recordings"
cd "$dir"

# The running container if there is one, otherwise a throwaway run of the same
# service: the SQLite backup API is safe against a live writer either way.
if [ -n "$(docker compose ps --status running --quiet tutor)" ]; then
  run=(docker compose exec -T tutor python -)
else
  run=(docker compose run --rm --no-deps -T --entrypoint python tutor -)
fi

"${run[@]}" <<'PY'
import datetime, os, sqlite3, sys

src_path = "/data/tutor.db"
if not os.path.exists(src_path):
    sys.exit("no database at " + src_path + " yet")
os.makedirs("/data/backups", exist_ok=True)
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
dest_path = "/data/backups/tutor-%s.db" % stamp
src = sqlite3.connect(src_path)
dst = sqlite3.connect(dest_path)
try:
    src.backup(dst)
    result = dst.execute("PRAGMA integrity_check").fetchone()[0]
finally:
    dst.close()
    src.close()
if result != "ok":
    os.remove(dest_path)
    sys.exit("backup failed its integrity check: " + result)
print("wrote " + dest_path)
PY

# Recordings are write-once: copy what is new, never overwrite, never delete.
if [ -d "${data}/recordings" ]; then
  cp -an "${data}/recordings/." "${out}/recordings/"
fi

# Keep the newest $keep database backups (the names sort by time).
find "$out" -maxdepth 1 -name 'tutor-*.db' | sort | head -n -"$keep" | xargs -r rm -f
echo "backups kept: $(find "$out" -maxdepth 1 -name 'tutor-*.db' | wc -l)"
BACKUP
}

_tutor_wait_ready() {
  local _
  for _ in $(seq 1 30); do
    if curl -fsS -m 5 "${SPANISH_TUTOR_URL}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# _tutor_tailscale_serve
#
# Publishes 127.0.0.1:8096 on the tailnet at https://<host>.<tailnet>.ts.net:8443/.
# Idempotent: `tailscale serve status --json` is read first and the command only
# runs when the :8443 entry is missing or points somewhere else. Tailnet only;
# this lib never calls `tailscale funnel`.
#
# The first `tailscale serve` on a tailnet needs HTTPS certificates enabled in
# the admin console. Without that the command prints a link and waits, so it
# runs under a timeout and the warning says what to do.
_tutor_tailscale_serve() {
  local want="$SPANISH_TUTOR_URL" have status
  if ! command -v tailscale >/dev/null 2>&1; then
    log "  WARNING: tailscale is not installed — the tutor is only on 127.0.0.1."
    return 1
  fi
  if ! status="$(tailscale serve status --json 2>/dev/null)"; then
    log "  WARNING: 'tailscale serve status' failed (logged in to the tailnet?) — not publishing."
    return 1
  fi
  have="$(jq -r --arg p ":${SPANISH_TUTOR_HTTPS_PORT}" \
    '[(.Web // {}) | to_entries[] | select(.key | endswith($p)) | .value.Handlers["/"].Proxy] | first // ""' \
    <<<"$status")"
  if jq -e --arg p ":${SPANISH_TUTOR_HTTPS_PORT}" \
       '(.AllowFunnel // {}) | to_entries | any(.[]; (.key | endswith($p)) and .value == true)' \
       <<<"$status" >/dev/null; then
    log "  ERROR: Funnel is on for :${SPANISH_TUTOR_HTTPS_PORT}, so the tutor would be public."
    log "         Turn it off with 'sudo tailscale funnel --https=${SPANISH_TUTOR_HTTPS_PORT} off', then re-run."
    return 1
  fi
  if [ "$have" = "$want" ]; then
    log "  tailscale serve already publishes ${want} on :${SPANISH_TUTOR_HTTPS_PORT}"
    return 0
  fi
  [ -z "$have" ] || log "  :${SPANISH_TUTOR_HTTPS_PORT} serves ${have} — replacing it with ${want}"
  if timeout 60 $SUDO tailscale serve --bg --https="$SPANISH_TUTOR_HTTPS_PORT" "$want" >/dev/null 2>&1; then
    log "  tailscale serve now publishes ${want} on :${SPANISH_TUTOR_HTTPS_PORT} (tailnet only)"
    return 0
  fi
  log "  WARNING: 'tailscale serve' failed. If the tailnet has HTTPS certificates off, enable them in"
  log "           the admin console (DNS, HTTPS Certificates), then re-run this script."
  return 1
}

# _tutor_prune_images
#
# Each bump builds a new image. Remove the older ones for this repo.
_tutor_prune_images() {
  local tag
  docker image ls "$SPANISH_TUTOR_IMAGE_REPO" --format '{{.Tag}}' | while read -r tag; do
    # Only the commit tags this lib builds (12 hex characters).
    [[ "$tag" =~ ^[0-9a-f]{12}$ ]] || continue
    [ "${SPANISH_TUTOR_IMAGE_REPO}:${tag}" = "$SPANISH_TUTOR_IMAGE" ] && continue
    docker image rm "${SPANISH_TUTOR_IMAGE_REPO}:${tag}" >/dev/null 2>&1 \
      && log "  removed old image ${SPANISH_TUTOR_IMAGE_REPO}:${tag}"
  done
  return 0
}
