#!/usr/bin/env bash
# LiteLLM: the one OpenAI-compatible endpoint on this box for local agents
# (Hermes), scripts and, later, Open WebUI.
#
#   install_litellm   writes the compose stack and config, the systemd unit,
#                     starts it, and makes a virtual key per client
#
# Expects the caller to have defined `log` and `$SUDO`, same as lib/codex.sh,
# and `$REPO_ROOT`, for the model list in ansible/group_vars/inference.yml.
#
# WHY A GATEWAY AT ALL
#
# llama-swap on the EVO-X2 does no authentication; the tailnet policy is all
# that stands in front of it. LiteLLM gives each client its own key, so a
# client can be cut off alone, and it logs every request with that key, which
# is where per-client token counts come from. Claude Code does NOT go through
# it: Claude keeps talking to Anthropic directly, and no cloud model is in any
# fallback chain here, so a local request can never quietly leave the house.
#
# SHAPE
#
#   litellm   network_mode: host, listening on 127.0.0.1:4000 only. Host
#             networking is what lets it resolve `evo-x2` through MagicDNS and
#             reach it over tailscale0 as this machine; on a bridge it would
#             need its own DNS and would leave the host as a NATed container.
#   postgres  on its own bridge, published on 127.0.0.1:5433. Virtual keys and
#             spend logs need a database; without one LiteLLM only knows the
#             master key. 5433 rather than 5432 so a Postgres installed on the
#             host later does not collide.
#
# Both images are pinned by tag AND digest. LiteLLM cuts several releases a
# day across parallel trains, so "latest" would be a different build on every
# re-run.
#
# SECRETS
#
# ~/.secrets/litellm/litellm.env holds the master key, the salt key and the
# database password, generated once on the first run. The salt key encrypts
# provider credentials stored in the database; changing it makes them
# unreadable, so it is never regenerated. Each client's virtual key goes in
# ~/.secrets/litellm/<client>.key.
#
# A subdirectory, not files at the top of ~/.secrets: every interactive shell
# sources each top-level file there (dotfiles 55_secrets.sh). A bare key file
# then runs as a command and prints "command not found: sk-..." with the key
# in it, and the env file would put the master key into every shell.

LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:v1.106.4@sha256:c169fb3adc514fcf210377c203f3de406d54f10bfdacf13948a4a839db9af7de}"
LITELLM_PG_IMAGE="${LITELLM_PG_IMAGE:-postgres:17-alpine@sha256:eee6c6e1b0894fa4fe0075eb054af9fd1cf39a35321c2d4110626cfe506411fb}"
LITELLM_DIR="${LITELLM_DIR:-$HOME/.local/share/litellm}"
LITELLM_SECRETS_DIR="${LITELLM_SECRETS_DIR:-$HOME/.secrets/litellm}"
LITELLM_SECRETS="${LITELLM_SECRETS:-$LITELLM_SECRETS_DIR/litellm.env}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_PG_PORT="${LITELLM_PG_PORT:-5433}"
LITELLM_URL="http://127.0.0.1:${LITELLM_PORT}"
# llama-swap on the EVO-X2. The short MagicDNS name, so nothing here commits a
# tailnet address (the repo is public).
LITELLM_UPSTREAM="${LITELLM_UPSTREAM:-http://evo-x2:8080/v1}"
# Clients that get a virtual key: Hermes's two profiles, and scripts. Open
# WebUI joins when it is installed.
LITELLM_CLIENTS="${LITELLM_CLIENTS:-hermes-lab hermes-restricted scripts}"

# install_litellm
#
# Idempotent. Rewrites the generated files every run, restarts the stack only
# when one of them changed, and creates a client key only when its file is
# missing. Returns non-zero if the stack does not come up.
install_litellm() {
  local unit_path=/etc/systemd/system/litellm.service tmp changed=0

  if ! command -v docker >/dev/null 2>&1; then
    log "  WARNING: docker is not installed — skipping LiteLLM."
    return 1
  fi

  mkdir -p "$LITELLM_DIR" "$LITELLM_SECRETS_DIR"
  chmod 700 "$HOME/.secrets" "$LITELLM_SECRETS_DIR"
  _litellm_migrate_secrets
  _litellm_ensure_secrets

  local f rc
  for f in compose config; do
    rc=0
    _litellm_write_if_changed "$LITELLM_DIR/${f}.yaml" "_litellm_${f}" || rc=$?
    case $rc in
      0) changed=1 ;;
      1) ;;
      *) log "  WARNING: could not generate ${f}.yaml — skipping LiteLLM."; return 1 ;;
    esac
  done

  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Managed by dev-environment/provision/lib/litellm.sh — do not edit by hand.
[Unit]
Description=LiteLLM gateway (local model endpoint on 127.0.0.1:${LITELLM_PORT})
Requires=docker.service
After=docker.service network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${USER}
WorkingDirectory=${LITELLM_DIR}
# --wait returns once both containers report healthy, so "active" means the
# gateway answers. restart: unless-stopped in the compose file covers crashes
# in between; this unit only owns boot and shutdown.
ExecStart=/usr/bin/docker compose --env-file ${LITELLM_SECRETS} up -d --wait --remove-orphans
ExecStop=/usr/bin/docker compose --env-file ${LITELLM_SECRETS} down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
  if $SUDO cmp -s "$tmp" "$unit_path" 2>/dev/null; then
    log "  litellm.service already current"
  else
    $SUDO cp "$tmp" "$unit_path"
    $SUDO chmod 644 "$unit_path"
    $SUDO systemctl daemon-reload
    changed=1
  fi
  rm -f "$tmp"
  $SUDO systemctl enable litellm.service >/dev/null 2>&1 || true

  if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet litellm.service; then
    log "  (re)starting litellm.service"
    # restart, not start: RemainAfterExit keeps a oneshot "active" after the
    # containers are gone, and start would then do nothing.
    if ! $SUDO systemctl restart litellm.service; then
      log "  WARNING: litellm.service failed — check 'journalctl -u litellm' and"
      log "           'docker compose -f ${LITELLM_DIR}/compose.yaml logs'."
      return 1
    fi
  fi

  if ! _litellm_wait_ready; then
    log "  WARNING: LiteLLM did not become ready on ${LITELLM_URL}."
    return 1
  fi
  log "  LiteLLM ready on ${LITELLM_URL}"

  local client
  for client in $LITELLM_CLIENTS; do
    _litellm_ensure_key "$client"
  done
}

# _litellm_ensure_secrets
#
# Creates ~/.secrets/litellm/litellm.env once. Never rewrites an existing file: the
# salt key must not change, and the database password is baked into the
# Postgres volume on its first start.
_litellm_ensure_secrets() {
  if [ -s "$LITELLM_SECRETS" ]; then
    return 0
  fi
  log "  generating ${LITELLM_SECRETS} (master key, salt key, database password)"
  ( umask 077
    cat >"$LITELLM_SECRETS" <<EOF
# Generated by dev-environment/provision/lib/litellm.sh. Keep it.
# LITELLM_SALT_KEY encrypts credentials stored in the database: never change it.
LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)
LITELLM_SALT_KEY=sk-$(openssl rand -hex 24)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
EOF
  )
}

# _litellm_write_if_changed <path> <generator>
#
# Runs the generator into a temp file and moves it into place only if it
# differs. Returns 0 if the file changed, 1 if not, 2 if the generator failed.
_litellm_write_if_changed() {
  local path="$1" gen="$2" tmp
  tmp="$(mktemp)"
  if ! "$gen" >"$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  if cmp -s "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$path"
  chmod 644 "$path"
  return 0
}

_litellm_compose() {
  cat <<EOF
# Managed by dev-environment/provision/lib/litellm.sh — do not edit by hand.
# Variables come from ${LITELLM_SECRETS} (passed with --env-file by litellm.service).
name: litellm

services:
  postgres:
    image: ${LITELLM_PG_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_USER: litellm
      POSTGRES_DB: litellm
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    ports:
      - "127.0.0.1:${LITELLM_PG_PORT}:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U litellm -d litellm"]
      interval: 10s
      timeout: 5s
      retries: 10

  litellm:
    image: ${LITELLM_IMAGE}
    restart: unless-stopped
    network_mode: host
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      LITELLM_MASTER_KEY: \${LITELLM_MASTER_KEY}
      LITELLM_SALT_KEY: \${LITELLM_SALT_KEY}
      DATABASE_URL: postgresql://litellm:\${POSTGRES_PASSWORD}@127.0.0.1:${LITELLM_PG_PORT}/litellm
      # No usage reporting to BerriAI.
      LITELLM_TELEMETRY: "False"
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--host", "127.0.0.1", "--port", "${LITELLM_PORT}"]
    healthcheck:
      # The image has python but not curl.
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${LITELLM_PORT}/health/liveliness', timeout=5)"]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 60s

volumes:
  pgdata:
EOF
}

# _litellm_config
#
# The model list comes from ansible/group_vars/inference.yml, the same file
# that tells llama-swap what to serve, so a model added there shows up here on
# the next run instead of in two places by hand.
#
#   local-qwen          the working model: the first entry of llama_swap_preload.
#                       Clients should ask for this, so a bake-off result is a
#                       one-line change in group_vars, not a change in every
#                       client.
#   <llama-swap name>   every model llama-swap serves, by its own name.
#
# local-qwen falls back to the llama.cpp model if its engine fails, so a broken
# Gufo release still leaves a local model answering. Both fallbacks are local.
#
# Timeouts are long on purpose: asking for a model that is not loaded makes
# llama-swap stop one and start the other, and Flash-Next takes 1-2 minutes to
# read in. No retries: a retry during a swap just queues a second swap.
_litellm_config() {
  local vars="${REPO_ROOT}/ansible/group_vars/inference.yml"
  python3 - "$vars" "$LITELLM_UPSTREAM" <<'PY'
import sys, yaml

vars_path, upstream = sys.argv[1], sys.argv[2]
try:
    with open(vars_path) as f:
        g = yaml.safe_load(f) or {}
except OSError as e:
    sys.exit(f"  ERROR: cannot read {vars_path}: {e}")

models = g.get("llama_swap_models") or {}
if not models:
    sys.exit(f"  ERROR: no llama_swap_models in {vars_path}")
preload = g.get("llama_swap_preload") or []
working = preload[0] if preload else next(iter(models))
fallback = next((n for n, m in models.items()
                 if m.get("engine") == "llama.cpp" and n != working), None)

def entry(name, target):
    return {
        "model_name": name,
        "litellm_params": {
            "model": f"openai/{target}",
            "api_base": upstream,
            # llama-swap has no auth; the OpenAI client still wants a key.
            "api_key": "none",
            "timeout": 900,
            "stream_timeout": 300,
        },
    }

cfg = {
    "model_list": [entry("local-qwen", working)]
                  + [entry(n, n) for n in models],
    "router_settings": {"num_retries": 0},
    "litellm_settings": {
        "request_timeout": 900,
        "drop_params": True,
        # Token and request counters on /metrics, for Alloy to send to the
        # Local model usage dashboard (docs/lab-metrics.md). Only the metrics
        # named here are exported, each with only the labels it lists:
        # api_key_alias is the client, requested_model what it asked for,
        # model what actually answered (differs after a fallback).
        "callbacks": ["prometheus"],
        # /metrics is on 127.0.0.1 like everything else here, and carries no
        # key material once the hash label is gone.
        "require_auth_for_metrics_endpoint": False,
        "prometheus_metrics_config": [
            {"group": "tokens",
             "metrics": ["litellm_input_tokens_metric",
                         "litellm_output_tokens_metric",
                         "litellm_input_cached_tokens_metric"],
             "include_labels": ["api_key_alias", "requested_model", "model"]},
            {"group": "requests",
             "metrics": ["litellm_proxy_total_requests_metric"],
             "include_labels": ["api_key_alias", "requested_model", "status_code"]},
            {"group": "failures",
             "metrics": ["litellm_proxy_failed_requests_metric"],
             "include_labels": ["api_key_alias", "requested_model", "exception_status"]},
            {"group": "latency",
             "metrics": ["litellm_request_total_latency_metric",
                         "litellm_llm_api_time_to_first_token_metric"],
             "include_labels": ["api_key_alias", "requested_model"]},
        ],
    },
    "general_settings": {
        "master_key": "os.environ/LITELLM_MASTER_KEY",
        "database_url": "os.environ/DATABASE_URL",
        "store_model_in_db": False,
    },
}
if fallback:
    cfg["router_settings"]["fallbacks"] = [{"local-qwen": [fallback]}]

print("# Managed by dev-environment/provision/lib/litellm.sh — do not edit by hand.")
print("# Generated from ansible/group_vars/inference.yml (llama_swap_models, llama_swap_preload).")
print(yaml.safe_dump(cfg, sort_keys=False), end="")
PY
}

_litellm_wait_ready() {
  local _
  for _ in $(seq 1 60); do
    if curl -fsS -m 5 "${LITELLM_URL}/health/readiness" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# _litellm_migrate_secrets
#
# Moves secrets from where the first version of this lib wrote them, the top
# of ~/.secrets, into ~/.secrets/litellm/. Moved, never regenerated: the salt
# key must survive, and the client keys are already in the database.
_litellm_migrate_secrets() {
  local old new f
  for f in "$HOME"/.secrets/litellm.env "$HOME"/.secrets/litellm-*.key; do
    [ -f "$f" ] || continue
    old="$(basename "$f")"
    case "$old" in
      litellm.env) new="$LITELLM_SECRETS" ;;
      *) new="$LITELLM_SECRETS_DIR/${old#litellm-}" ;;
    esac
    if [ -e "$new" ]; then
      log "  WARNING: both ${f} and ${new} exist — leaving ${f} for you to delete"
    else
      mv "$f" "$new" && log "  moved ${f} to ${new}"
    fi
  done
}

# _litellm_ensure_key <client>
#
# One virtual key per client, saved to ~/.secrets/litellm/<client>.key. Not
# limited to a model list: every model in this gateway is local, and a list
# fixed at creation would lock a key out of models added later. A key whose file exists and still validates
# is left alone. If the file is gone but the database still has a key with that
# alias, a new one is made anyway and the old one stays until it is deleted in
# the admin UI (http://127.0.0.1:4000/ui).
_litellm_ensure_key() {
  local client="$1" file="$LITELLM_SECRETS_DIR/$1.key" master key
  master="$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$LITELLM_SECRETS")"

  if [ -s "$file" ]; then
    key="$(cat "$file")"
    if curl -fsS -m 10 -H "Authorization: Bearer ${key}" "${LITELLM_URL}/v1/models" >/dev/null 2>&1; then
      log "  LiteLLM key for ${client} already in place"
      return 0
    fi
    log "  WARNING: ${file} no longer validates — making a new key for ${client}"
  fi

  key="$(curl -fsS -m 20 -X POST "${LITELLM_URL}/key/generate" \
      -H "Authorization: Bearer ${master}" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg a "$client" '{key_alias: $a, metadata: {managed_by: "dev-environment"}}')" \
    | jq -r '.key // empty')" || true
  if [ -z "$key" ]; then
    log "  WARNING: LiteLLM refused to make a key for ${client}"
    return 1
  fi
  ( umask 077; printf '%s\n' "$key" >"$file" )
  log "  LiteLLM key for ${client} written to ${file}"
}
