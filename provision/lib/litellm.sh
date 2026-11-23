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
# it for models: Claude keeps talking to Anthropic directly (it uses the gateway
# for MCP only, below), and no cloud model is in any
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
# MCP GATEWAY
#
# LiteLLM is also the lab's MCP gateway (docs/mcp-gateway.md). An MCP server is
# registered once, here, with its credential; clients connect to LiteLLM's /mcp
# with their own virtual key and see only the servers that key is granted. The
# credential never reaches the client, and a client can be cut off or narrowed
# by its key alone. Tool names behind the gateway carry the server's name,
# `<server>-<tool>` (the separator is "-", so a server name cannot contain one).
#
#   LITELLM_MCP_SERVERS   the servers: name|url|token file|description
#   LITELLM_MCP_GRANTS    who may use which: client:server
#
# Adding a server is a line in each. Its token file is read on every run and
# passed to the container as an environment variable (~/.secrets/litellm/mcp.env,
# mode 600), and config.yaml, which is world-readable, only names the variable.
# A server whose token file is missing is left out with a warning, so run order
# between this lib and the one that creates the token does not matter.
#
# A key with NO grant is not a key with no MCP access: LiteLLM treats a key
# without an MCP scope as unrestricted, so every client not named in
# LITELLM_MCP_GRANTS is explicitly set to the "no-mcp-servers" marker.
#
# Host networking decides where an MCP server can live. LiteLLM runs on the host
# network, so it reaches a server at 127.0.0.1:<port>; it cannot see a name on a
# Docker bridge network. Servers therefore publish a port on 127.0.0.1 only
# (the curator already does). Moving LiteLLM onto a bridge, with models reached
# through host.docker.internal or a tailscale sidecar, would let servers stay
# unpublished on an internal network; that is a larger change than this lib makes.
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
# Needed for the model list; set by the bootstrap scripts, derived when this lib
# is sourced from one that does not (content-curator-setup.sh).
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# llama-swap on the EVO-X2. The short MagicDNS name, so nothing here commits a
# tailnet address (the repo is public).
LITELLM_UPSTREAM="${LITELLM_UPSTREAM:-http://evo-x2:8080/v1}"
# Clients that get a virtual key: Hermes's two profiles, scripts, and the
# content curator (github.com/warroyo/content-curator) and the Spanish tutor
# (github.com/warroyo/spanish-tutor). Open WebUI joins when it is installed.
# claude-code is Claude Code on this box, which uses LiteLLM for MCP only;
# ask-qwen is the one-shot helper Claude pipes big inputs into (docs/local-ai.md).
LITELLM_CLIENTS="${LITELLM_CLIENTS:-hermes-lab hermes-restricted scripts content-curator claude-code ask-qwen spanish-tutor}"

# MCP servers behind the gateway (see MCP GATEWAY above): name|url|token file|description.
# The content curator's token file and port are set in lib/content-curator.sh;
# keep them in step. Names use underscores, never "-".
LITELLM_MCP_SERVERS=(
  "content_curator|http://127.0.0.1:8090/mcp|${HOME}/.secrets/content-curator/api-token|Content curator: picks, feedback, sources and its weekly review"
)
# client:server. Every client not listed gets no MCP servers at all.
LITELLM_MCP_GRANTS=(
  "claude-code:content_curator"
  "hermes-lab:content_curator"
)
LITELLM_MCP_ENV="${LITELLM_MCP_ENV:-$LITELLM_SECRETS_DIR/mcp.env}"
# What Claude Code and the Hermes lab profile call the gateway. A tool then reads
# mcp__litellm__<server>-<tool> in Claude Code.
LITELLM_MCP_CLIENT_NAME="${LITELLM_MCP_CLIENT_NAME:-litellm}"
# Direct registrations from before the gateway, removed when clients connect to it.
LITELLM_MCP_LEGACY_NAMES="${LITELLM_MCP_LEGACY_NAMES:-content_curator}"
LITELLM_CLAUDE_BIN="${LITELLM_CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
LITELLM_HERMES_BIN="${LITELLM_HERMES_BIN:-$HOME/.local/bin/hermes}"

# install_litellm
#
# Idempotent. Rewrites the generated files every run, restarts the stack only
# when one of them changed, and creates a client key only when its file is
# missing (its MCP grants are reconciled every run). Returns non-zero if the stack does not come up.
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

  _litellm_mcp_warn_missing
  local f rc
  _litellm_write_if_changed "$LITELLM_MCP_ENV" _litellm_mcp_env 600 && changed=1
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

# _litellm_write_if_changed <path> <generator> [mode]
#
# Runs the generator into a temp file and moves it into place only if it
# differs. Returns 0 if the file changed, 1 if not, 2 if the generator failed.
_litellm_write_if_changed() {
  local path="$1" gen="$2" mode="${3:-644}" tmp
  tmp="$(mktemp)"
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

# _litellm_mcp_var <server>
# The environment variable that carries a server's token: MCP_<NAME>_TOKEN.
_litellm_mcp_var() {
  local n="${1^^}"
  printf 'MCP_%s_TOKEN' "$n"
}

# _litellm_mcp_active
# One line per server whose token file has content: name|url|variable|description.
_litellm_mcp_active() {
  local row name url file desc
  for row in "${LITELLM_MCP_SERVERS[@]}"; do
    IFS='|' read -r name url file desc <<<"$row"
    [ -s "$file" ] || continue
    printf '%s|%s|%s|%s\n' "$name" "$url" "$(_litellm_mcp_var "$name")" "$desc"
  done
}

_litellm_mcp_warn_missing() {
  local row name file
  for row in "${LITELLM_MCP_SERVERS[@]}"; do
    IFS='|' read -r name _ file _ <<<"$row"
    [ -s "$file" ] || log "  WARNING: ${file} is missing — MCP server ${name} is left out of the gateway until it exists."
  done
}

# _litellm_mcp_env
# The tokens, one VARIABLE=value line per active server, for the container's env_file.
_litellm_mcp_env() {
  local row name file
  echo "# Generated by dev-environment/provision/lib/litellm.sh. MCP server tokens, read from their own files."
  for row in "${LITELLM_MCP_SERVERS[@]}"; do
    IFS='|' read -r name _ file _ <<<"$row"
    [ -s "$file" ] || continue
    printf '%s=%s\n' "$(_litellm_mcp_var "$name")" "$(tr -d '[:space:]' <"$file")"
  done
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
    # MCP server tokens (see MCP GATEWAY). Optional: absent means no servers.
    env_file:
      - path: ${LITELLM_MCP_ENV}
        required: false
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
#   <alias>             a model's `alias` from group_vars, such as local-embed
#                       for the embedding model, so clients name a role rather
#                       than a model.
#
# local-qwen falls back to the llama.cpp model if its engine fails, so a broken
# Gufo release still leaves a local model answering. Both fallbacks are local.
#
# Timeouts are long on purpose: asking for a model that is not loaded makes
# llama-swap stop one and start the other, and Flash-Next takes 1-2 minutes to
# read in. No retries: a retry during a swap just queues a second swap.
_litellm_config() {
  local vars="${REPO_ROOT}/ansible/group_vars/inference.yml"
  python3 - "$vars" "$LITELLM_UPSTREAM" $'\n'"$(_litellm_mcp_active)" <<'PY'
import sys, yaml

vars_path, upstream = sys.argv[1], sys.argv[2]
mcp_rows = [r for r in sys.argv[3].split("\n") if r.strip()]
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
# The chat fallback must be a chat model, never the embedding model.
fallback = next((n for n, m in models.items()
                 if m.get("engine") == "llama.cpp" and n != working
                 and m.get("mode", "chat") == "chat"), None)

def entry(name, target):
    e = {
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
    mode = models.get(target, {}).get("mode")
    if mode and mode != "chat":
        e["model_info"] = {"mode": mode}
    return e

aliases = [entry(m["alias"], n) for n, m in models.items() if m.get("alias")]

cfg = {
    "model_list": [entry("local-qwen", working)]
                  + aliases
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
# MCP servers (see MCP GATEWAY in lib/litellm.sh). The token is an environment
# reference, never the value: this file is world-readable.
mcp = {}
for row in mcp_rows:
    name, url, var, desc = (row.split("|", 3) + [""])[:4]
    server = {
        "server_id": name,  # pinned, so grants survive an edit to url or auth
        "transport": "http",
        "url": url,
        "auth_type": "bearer_token",
        "authentication_token": f"os.environ/{var}",
    }
    if desc:
        server["description"] = desc
    mcp[name] = server
if mcp:
    cfg["mcp_servers"] = mcp
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

# _litellm_key_mcp <client>
#
# The client's object_permission as JSON: the servers it is granted in
# LITELLM_MCP_GRANTS, or the "no-mcp-servers" marker. An empty list would not
# do: LiteLLM reads a key with no MCP scope as allowed to use every server.
_litellm_key_mcp() {
  local client="$1" row servers=()
  for row in "${LITELLM_MCP_GRANTS[@]}"; do
    [ "${row%%:*}" = "$client" ] && servers+=("${row#*:}")
  done
  [ "${#servers[@]}" -gt 0 ] || servers=(no-mcp-servers)
  printf '%s\n' "${servers[@]}" | jq -R . | jq -sc '{mcp_servers: .}'
}

# _litellm_ensure_key <client>
#
# One virtual key per client, saved to ~/.secrets/litellm/<client>.key. Not
# limited to a model list: every model in this gateway is local, and a list
# fixed at creation would lock a key out of models added later. A key whose file
# exists and still validates is kept. If the file is gone but the database still
# has a key with that alias, a new one is made anyway and the old one stays until
# it is deleted in the admin UI (http://127.0.0.1:4000/ui).
#
# Either way the key's MCP grants are set to what LITELLM_MCP_GRANTS says, on
# every run: the keys that predate the gateway have to get them, and a grant
# removed from the table has to be taken away.
_litellm_ensure_key() {
  local client="$1" file="$LITELLM_SECRETS_DIR/$1.key" master key perm
  master="$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$LITELLM_SECRETS")"
  perm="$(_litellm_key_mcp "$client")"

  if [ -s "$file" ]; then
    key="$(cat "$file")"
    if curl -fsS -m 10 -H "Authorization: Bearer ${key}" "${LITELLM_URL}/v1/models" >/dev/null 2>&1; then
      log "  LiteLLM key for ${client} already in place"
      _litellm_set_key_mcp "$client" "$key" "$perm" "$master"
      return $?
    fi
    log "  WARNING: ${file} no longer validates — making a new key for ${client}"
  fi

  key="$(curl -fsS -m 20 -X POST "${LITELLM_URL}/key/generate" \
      -H "Authorization: Bearer ${master}" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg a "$client" --argjson p "$perm" \
            '{key_alias: $a, metadata: {managed_by: "dev-environment"}, object_permission: $p}')" \
    | jq -r '.key // empty')" || true
  if [ -z "$key" ]; then
    log "  WARNING: LiteLLM refused to make a key for ${client}"
    return 1
  fi
  ( umask 077; printf '%s\n' "$key" >"$file" )
  log "  LiteLLM key for ${client} written to ${file}"
  _litellm_set_key_mcp "$client" "$key" "$perm" "$master"
}

# _litellm_set_key_mcp <client> <key> <permission json> <master key>
_litellm_set_key_mcp() {
  local client="$1" key="$2" perm="$3" master="$4"
  if curl -fsS -m 20 -X POST "${LITELLM_URL}/key/update" \
      -H "Authorization: Bearer ${master}" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg k "$key" --argjson p "$perm" '{key: $k, object_permission: $p}')" >/dev/null; then
    log "  MCP access for ${client}: $(jq -r '.mcp_servers | join(", ")' <<<"$perm")"
  else
    log "  WARNING: could not set MCP access on the ${client} key"
    return 1
  fi
}

# litellm_connect_clients
#
# Points Claude Code (user scope) and the Hermes lab profile at the gateway's
# /mcp, each with its own key, and removes their direct registrations of servers
# that now sit behind it. Lives here rather than in the curator's lib because it
# is about the gateway, not any one server; lib/content-curator.sh calls it
# once the curator's token exists. Needs install_litellm to have run (the keys)
# and Hermes installed for its half, which is skipped if it is not.
#
# Claude Code sends the key as x-litellm-api-key, the header LiteLLM's MCP docs
# name. The Hermes entry keeps Authorization: Bearer, the form `hermes config
# set` already stored here and LiteLLM accepts for its own keys on /mcp.
litellm_connect_clients() {
  local url="${LITELLM_URL}/mcp" ck hk
  ck="$LITELLM_SECRETS_DIR/claude-code.key"
  hk="$LITELLM_SECRETS_DIR/hermes-lab.key"
  if [ -z "$(_litellm_mcp_active)" ]; then
    log "  no MCP servers in the gateway — not registering it with Claude Code or Hermes."
    return 1
  fi
  if [ ! -s "$ck" ] || ! curl -fsS -m 15 -o /dev/null -X POST "$url" \
      -H "x-litellm-api-key: Bearer $(cat "$ck")" \
      -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'; then
    log "  WARNING: ${url} does not answer for the claude-code key — not registering the gateway."
    return 1
  fi

  local name="$LITELLM_MCP_CLIENT_NAME" old
  if [ -x "$LITELLM_CLAUDE_BIN" ]; then
    for old in $LITELLM_MCP_LEGACY_NAMES "$name"; do
      "$LITELLM_CLAUDE_BIN" mcp remove --scope user "$old" >/dev/null 2>&1 || true
    done
    if "$LITELLM_CLAUDE_BIN" mcp add --scope user --transport http "$name" "$url" \
        --header "x-litellm-api-key: Bearer $(cat "$ck")" >/dev/null 2>&1; then
      log "  LiteLLM MCP registered with Claude Code (${name})"
    else
      log "  WARNING: 'claude mcp add ${name}' failed"
    fi
  fi

  [ -x "$LITELLM_HERMES_BIN" ] && [ -s "$hk" ] || return 0
  _litellm_hermes_mcp "$url" "$(tr -d '[:space:]' <"$hk")"
}

# _litellm_hermes_mcp <url> <key>
#
# Sets the lab profile's MCP entry, drops the legacy direct ones, and restarts
# the gateway only when something changed. Compared in config.yaml itself:
# `hermes config get` masks the header.
_litellm_hermes_mcp() {
  local url="$1" key="$2" name="$LITELLM_MCP_CLIENT_NAME" config current old changed=0
  config="$("$LITELLM_HERMES_BIN" config path 2>/dev/null)"
  current="$(python3 - "$config" "$name" <<'PY' 2>/dev/null
import sys, yaml
server = ((yaml.safe_load(open(sys.argv[1])) or {}).get("mcp_servers") or {}).get(sys.argv[2]) or {}
print(server.get("url", ""), (server.get("headers") or {}).get("Authorization", ""))
PY
)"
  if [ "$current" != "${url} Bearer ${key}" ]; then
    if ! "$LITELLM_HERMES_BIN" config set "mcp_servers.${name}.url" "$url" >/dev/null 2>&1 \
        || ! "$LITELLM_HERMES_BIN" config set "mcp_servers.${name}.headers.Authorization" "Bearer ${key}" >/dev/null 2>&1; then
      log "  WARNING: could not add the LiteLLM MCP to Hermes' config"
      return 1
    fi
    log "  LiteLLM MCP added to Hermes' lab profile (${name})"
    changed=1
  fi
  for old in $LITELLM_MCP_LEGACY_NAMES; do
    if python3 - "$config" "$old" <<'PY' 2>/dev/null
import sys, yaml
sys.exit(0 if ((yaml.safe_load(open(sys.argv[1])) or {}).get("mcp_servers") or {}).get(sys.argv[2]) else 1)
PY
    then
      "$LITELLM_HERMES_BIN" config unset "mcp_servers.${old}" >/dev/null 2>&1 \
        && { log "  removed the direct ${old} MCP entry from Hermes' lab profile"; changed=1; }
    fi
  done
  [ "$changed" -eq 1 ] || return 0
  # The same stop-then-start as lib/hermes.sh's configure_hermes_telegram, for
  # the same reasons: Hermes connects to MCP servers when its gateway starts.
  # Only when a gateway runs: otherwise the next start loads it. `cron status`
  # exits 0 either way; its output says whether a gateway runs.
  if "$LITELLM_HERMES_BIN" cron status 2>/dev/null | grep -q 'Gateway is running'; then
    "$LITELLM_HERMES_BIN" gateway stop --all >/dev/null 2>&1 || true
    if timeout 120 "$LITELLM_HERMES_BIN" gateway start >/dev/null 2>&1; then
      log "  restarted the Hermes gateway to load it"
    else
      log "  WARNING: 'hermes gateway start' failed or timed out — check 'hermes gateway status'"
    fi
  fi
}
