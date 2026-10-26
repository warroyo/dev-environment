#!/usr/bin/env bash
# Hermes Agent on the local model, in two profiles.
#
#   ensure_hermes                 installs the CLI (stable channel)
#   install_hermes_sandbox_net    the Docker network the restricted profile's
#                                 commands run in, and the firewall rules that
#                                 keep it on the internet only
#   configure_hermes              sets up both profiles on LiteLLM, one
#                                 `hermes config set` at a time
#
# Expects the caller to have defined `log` and `$SUDO`, same as lib/codex.sh.
# Runs after install_litellm, which writes ~/.secrets/litellm/hermes-lab.key
# and litellm-hermes-restricted.key.
#
# How Claude delegates to it is in docs/local-ai.md and the `hermes` skill
# (dotfiles/dot_claude/skills/hermes).

HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
HERMES_SANDBOX_NET="${HERMES_SANDBOX_NET:-hermes-sandbox}"
HERMES_SANDBOX_BRIDGE="${HERMES_SANDBOX_BRIDGE:-br-hermes}"

# ensure_hermes
#
# Installs Hermes unless it is already there. Not pinned: like Claude Code and
# Codex, Hermes updates itself (`hermes update`) and its installer has no
# version flag, only a channel. `stable` is the latest tagged release.
#
# SHELL=/bin/bash is deliberate. The installer appends a PATH line to the rc
# files of the login shell unless they already set ~/.local/bin on PATH, and
# for zsh that means ~/.zshrc, which chezmoi owns here, so the next apply
# would revert it. ~/.local/bin is already on PATH (dot_zshenv), and
# ~/.bashrc and ~/.profile already carry the line, so as bash it edits
# nothing.
ensure_hermes() {
  if [ -x "$HERMES_BIN" ]; then
    log "  Hermes already installed ($("$HERMES_BIN" --version 2>/dev/null | head -n1 || echo 'version unknown'))"
    return 0
  fi
  if SHELL=/bin/bash PATH="$HOME/.local/bin:$PATH" \
       bash -c "curl -fsSL '$HERMES_INSTALL_URL' | bash -s -- --channel stable --non-interactive --skip-browser --skip-computer-use"; then
    log "  Hermes installed ($("$HERMES_BIN" --version 2>/dev/null | head -n1))"
    return 0
  fi
  log "  WARNING: Hermes install failed. Retry by re-running this script, or by hand:"
  log "           curl -fsSL ${HERMES_INSTALL_URL} | SHELL=/bin/bash bash -s -- --non-interactive"
  return 1
}

# install_hermes_sandbox_net
#
# Every command the restricted profile runs goes into a throwaway container on
# this network. (The lab profile runs on the host and does not use it.)
# The network reaches the internet (package installs, git clones, docs) and
# nothing else:
#
#   - not tun0, the client-lab VPN. Without a rule, Docker's NAT sends a
#     container's 10.47.7.x traffic straight down the tunnel, because routing
#     happens in the host's table.
#   - not the tailnet. This box is untagged and owned by Will, so a container
#     NATed out of it would reach every lab machine, including llama-swap on
#     the EVO-X2, which has no auth.
#   - not the LAN, and not this host's own services (sshd, dnsmasq, Postgres).
#
# The rules sit in the raw table's PREROUTING chain, which runs before routing
# and before any filter chain. They first went in DOCKER-USER, the chain Docker
# leaves alone, and a test from the sandbox still reached llama-swap on the
# EVO-X2: tailscaled puts its ts-forward chain at the top of FORWARD, and it
# ACCEPTs everything leaving through tailscale0 before DOCKER-USER is reached.
# Matching on destination before routing does not depend on chain order, and
# it covers tun0 (10.47.7.0/24 and 172.21.0.90 are private) and the host's own
# addresses too. The INPUT rule stays as a second line for traffic to the host.
# A container's DNS still works: Docker's embedded resolver answers inside the
# container's namespace and forwards from the host, not through these chains.
#
# The rules are applied by a oneshot unit tied to docker.service, because
# iptables rules do not survive a reboot. The named bridge is what the rules
# match, so they hold whatever subnet Docker picks for the network.
install_hermes_sandbox_net() {
  local unit_path=/etc/systemd/system/hermes-sandbox-egress.service
  local script_path=/usr/local/sbin/hermes-sandbox-egress tmp changed=0

  if ! docker network inspect "$HERMES_SANDBOX_NET" >/dev/null 2>&1; then
    docker network create --driver bridge \
      -o "com.docker.network.bridge.name=${HERMES_SANDBOX_BRIDGE}" \
      "$HERMES_SANDBOX_NET" >/dev/null
    log "  created Docker network ${HERMES_SANDBOX_NET} (${HERMES_SANDBOX_BRIDGE})"
  else
    log "  Docker network ${HERMES_SANDBOX_NET} already exists"
  fi

  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
#!/bin/sh
# Managed by dev-environment/provision/lib/hermes.sh — do not edit by hand.
# Keeps Hermes' sandbox containers (bridge ${HERMES_SANDBOX_BRIDGE}) on the
# internet only: no LAN, no tailnet, no client VPN, no host services.
#   hermes-sandbox-egress add|del
set -eu
BR=${HERMES_SANDBOX_BRIDGE}
PRIVATE="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16"

rule() { # rule add|del <table> <chain> <args...>
  op=\$1 table=\$2 chain=\$3; shift 3
  if iptables -t "\$table" -C "\$chain" "\$@" 2>/dev/null; then
    [ "\$op" = del ] && iptables -t "\$table" -D "\$chain" "\$@"
  else
    [ "\$op" = add ] && iptables -t "\$table" -I "\$chain" 1 "\$@"
  fi
  return 0
}

op=\${1:-add}
for net in \$PRIVATE; do
  rule "\$op" raw PREROUTING -i "\$BR" -d "\$net" -j DROP
done
rule "\$op" filter INPUT -i "\$BR" -j DROP

# The first version's DOCKER-USER rules, which ts-forward bypassed. Removed
# on every run so an upgraded host does not keep them.
for r in "-o tun0" "-o tailscale0"; do
  # shellcheck disable=SC2086
  rule del filter DOCKER-USER -i "\$BR" \$r -j DROP
done
for net in \$PRIVATE; do
  rule del filter DOCKER-USER -i "\$BR" -d "\$net" -j DROP
done
EOF
  if ! $SUDO cmp -s "$tmp" "$script_path" 2>/dev/null; then
    $SUDO install -m 755 "$tmp" "$script_path"
    changed=1
  fi

  cat >"$tmp" <<EOF
# Managed by dev-environment/provision/lib/hermes.sh — do not edit by hand.
[Unit]
Description=Firewall rules keeping Hermes' sandbox containers off the LAN, tailnet and VPN
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${script_path} add
ExecStop=${script_path} del

[Install]
WantedBy=docker.service
EOF
  if ! $SUDO cmp -s "$tmp" "$unit_path" 2>/dev/null; then
    $SUDO cp "$tmp" "$unit_path"
    $SUDO chmod 644 "$unit_path"
    $SUDO systemctl daemon-reload
    changed=1
  fi
  rm -f "$tmp"

  $SUDO systemctl enable hermes-sandbox-egress.service >/dev/null 2>&1 || true
  if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet hermes-sandbox-egress.service; then
    $SUDO systemctl restart hermes-sandbox-egress.service || \
      { log "  WARNING: hermes-sandbox-egress.service failed — the sandbox is NOT isolated."; return 1; }
  fi
  log "  sandbox egress rules active on ${HERMES_SANDBOX_BRIDGE}"
}

# configure_hermes
#
# Two profiles, each its own Hermes home with its own memory, sessions and
# LiteLLM key:
#
#   lab (default, `hermes`)   The same access Claude has: commands run on this
#                             host as Will, so ~/.lab.env, the client lab
#                             through tun0, and agent SSH to the home lab over
#                             the tailnet all work. Held to the same lines as
#                             Claude (dotfiles/dot_claude/modify_settings.json):
#                             no admin SSH, no ansible. Changes to lab machines
#                             go through dev-environment code that Will runs.
#   restricted (`-p restricted`)
#                             Internet only. Commands run in a throwaway
#                             container on the hermes-sandbox network. The one
#                             thing it can write on the host is the vault's
#                             inbox/, for notes Will files later; no git, so
#                             nothing is pushed.
#
# Both: manual approval of every dangerous command, memory and skill writes
# approved first.
#
# Each setting goes through `hermes config set` rather than a templated
# config.yaml: Hermes migrates and rewrites its own config file across
# releases, and owning the whole file would fight that. Keys set here are put
# back on every run; anything else in the file is left alone.
HERMES_RESTRICTED_PROFILE="${HERMES_RESTRICTED_PROFILE:-restricted}"
HERMES_INBOX_DIR="${HERMES_INBOX_DIR:-$HOME/second-brain/inbox}"

configure_hermes() {
  local failed=0
  if [ ! -x "$HERMES_BIN" ]; then
    log "  WARNING: Hermes is not installed — skipping its configuration."
    return 1
  fi

  if ! "$HERMES_BIN" profile list 2>/dev/null | grep -qw "$HERMES_RESTRICTED_PROFILE"; then
    # Blank, not --clone: a clone would copy the lab profile's memory.
    if "$HERMES_BIN" profile create "$HERMES_RESTRICTED_PROFILE" >/dev/null 2>&1; then
      log "  created Hermes profile ${HERMES_RESTRICTED_PROFILE}"
    else
      log "  WARNING: could not create Hermes profile ${HERMES_RESTRICTED_PROFILE}"
      failed=1
    fi
  fi

  _hermes_configure_profile "" "$HOME/.secrets/litellm/hermes-lab.key" \
    "terminal.backend=local" \
    'approvals.deny=["ssh *-admin*", "ansible *", "*ansible-playbook*", "*ansible/play*"]' \
    || failed=1

  mkdir -p "$HERMES_INBOX_DIR"
  _hermes_configure_profile "$HERMES_RESTRICTED_PROFILE" "$HOME/.secrets/litellm/hermes-restricted.key" \
    "terminal.backend=docker" \
    "terminal.container_persistent=false" \
    "terminal.container_memory=4096" \
    "terminal.container_cpu=2" \
    "terminal.docker_mount_cwd_to_workspace=false" \
    "terminal.docker_extra_args=[\"--network\", \"${HERMES_SANDBOX_NET}\"]" \
    "terminal.docker_volumes=[\"${HERMES_INBOX_DIR}:/inbox\"]" \
    "terminal.docker_run_as_host_user=true" \
    "terminal.cwd=/inbox" \
    || failed=1

  # herdr's own integration: reports the session id, so herdr can resume the
  # conversation after a restart. It does not report state.
  if command -v herdr >/dev/null 2>&1; then
    if herdr integration install hermes >/dev/null 2>&1; then
      log "  herdr integration for Hermes installed"
    else
      log "  WARNING: 'herdr integration install hermes' failed"
    fi
    install_hermes_herdr_state "" || failed=1
    install_hermes_herdr_state "$HERMES_RESTRICTED_PROFILE" || failed=1
  fi
  return "$failed"
}

# install_hermes_herdr_state <profile|"">
#
# A Hermes plugin that tells herdr whether Hermes is working, blocked or idle.
#
# herdr reads Hermes's state off the screen: a ⏳/⚠/✓ glyph in the terminal
# title, or strings like "ctrl+c to interrupt" in the bottom lines. Hermes
# 0.22's TUI sets no title and prints neither string, so herdr falls back to
# idle the whole time (`herdr agent explain`: default_known_agent_idle_fallback)
# and `herdr agent wait` returns at once. herdr 0.9.0 has the same manifest, so
# upgrading herdr does not help.
#
# herdr also takes state pushed over its socket (pane.report_agent), which is
# what this plugin does, from Hermes's own lifecycle hooks:
#
#   pre_llm_call                              working (a turn started)
#   on_human_input_request, pre_approval_request   blocked (approval, clarify, sudo)
#   on_human_input_resolved, post_approval_response working again
#   on_session_end                            idle (fires once per turn, at its end)
#
# Only the top-level session counts; a subagent's turn ending must not mark
# the pane idle while the parent is still working. Outside herdr (no
# HERDR_PANE_ID) it does nothing.
#
# The hooks fire in the profile's shared gateway, which serves every Hermes
# pane, so the pane id comes from the session's client env rather than the
# gateway's own (see terminal.client_env_passthrough below).
#
# Its own directory, beside herdr's herdr-agent-state plugin rather than in
# it: herdr overwrites that one on every `herdr integration install`.
HERMES_HERDR_STATE_PLUGIN="herdr-push-state"

install_hermes_herdr_state() {
  local profile="$1" label="${1:-lab (default)}"
  local -a hermes=("$HERMES_BIN")
  local home="$HOME/.hermes"
  if [ -n "$profile" ]; then
    hermes+=(-p "$profile")
    home="$HOME/.hermes/profiles/$profile"
  fi
  local dir="$home/plugins/$HERMES_HERDR_STATE_PLUGIN"
  mkdir -p "$dir"

  cat >"$dir/plugin.yaml" <<EOF
# Managed by dev-environment/provision/lib/hermes.sh — do not edit by hand.
name: ${HERMES_HERDR_STATE_PLUGIN}
version: "1.0"
description: Push Hermes's working/blocked/idle state to the herdr pane it runs in
EOF

  cat >"$dir/__init__.py" <<'EOF'
"""Push Hermes's working/blocked/idle state to herdr (pane.report_agent).

Managed by dev-environment/provision/lib/hermes.sh; do not edit by hand.
Why it exists is in the comment above install_hermes_herdr_state there.
"""

from __future__ import annotations

import json
import os
import socket
import threading
import time

_SOURCE = "herdr:hermes-push-state"
_lock = threading.Lock()
_child_sessions: set[str] = set()  # subagents' sessions; their turns never touch the pane


def _env(name: str) -> str:
    # Hooks run in the profile's shared gateway, whose own environment is
    # whichever pane started it. The pane this session belongs to is in the
    # session's client env (terminal.client_env_passthrough lists HERDR_*).
    try:
        from agent.session_client_env import bound_client_env
        bound = bound_client_env()
    except Exception:
        bound = None
    if bound is not None:
        return str(bound.get(name, "")).strip()
    return os.environ.get(name, "").strip()


def _send(state: str) -> None:
    if _env("HERDR_ENV") != "1":
        return
    pane_id = _env("HERDR_PANE_ID")
    socket_path = _env("HERDR_SOCKET_PATH")
    if not pane_id or not socket_path:
        return
    seq = time.time_ns()
    request = {
        "id": f"{_SOURCE}:{seq}",
        "method": "pane.report_agent",
        "params": {"pane_id": pane_id, "source": _SOURCE, "agent": "hermes",
                   "state": state, "seq": seq},
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.5)
            client.connect(socket_path)
            client.sendall((json.dumps(request) + "\n").encode("utf-8"))
            try:
                client.recv(4096)
            except Exception:
                pass
    except Exception:
        pass  # herdr gone or busy: never let state reporting break a turn


def _turn_started(**kwargs) -> None:
    if kwargs.get("parent_session_id"):
        with _lock:
            _child_sessions.add(kwargs.get("session_id") or "")
        return
    _send("working")


def _turn_ended(**kwargs) -> None:
    with _lock:
        if kwargs.get("session_id") in _child_sessions:
            return
    _send("idle")


def _waiting(**_kwargs) -> None:
    _send("blocked")


def _resumed(**_kwargs) -> None:
    _send("working")


def register(ctx):
    ctx.register_hook("pre_llm_call", _turn_started)
    ctx.register_hook("on_session_end", _turn_ended)
    ctx.register_hook("on_human_input_request", _waiting)
    ctx.register_hook("pre_approval_request", _waiting)
    ctx.register_hook("on_human_input_resolved", _resumed)
    ctx.register_hook("post_approval_response", _resumed)
EOF

  if "${hermes[@]}" plugins enable "$HERMES_HERDR_STATE_PLUGIN" >/dev/null 2>&1; then
    log "  [${label}] herdr state plugin installed and enabled"
  else
    log "  WARNING: [${label}] 'hermes plugins enable ${HERMES_HERDR_STATE_PLUGIN}' failed"
    return 1
  fi
}

# _hermes_configure_profile <profile|""> <key file> [extra key=value ...]
#
# The settings both profiles share, then the profile's own.
_hermes_configure_profile() {
  local profile="$1" key_file="$2" label="${1:-lab (default)}"
  shift 2
  local -a hermes=("$HERMES_BIN")
  [ -n "$profile" ] && hermes+=(-p "$profile")

  if [ ! -s "$key_file" ]; then
    log "  WARNING: no ${key_file} — run install_litellm first. Skipping profile ${label}."
    return 1
  fi

  local -a settings=(
    # The model: everything through LiteLLM, by the alias, so a bake-off
    # result never touches this file. Responses API, because tool calls
    # through Chat Completions were unreliable for Hermes on these models.
    "model.provider=custom"
    "model.base_url=http://127.0.0.1:4000/v1"
    "model.default=local-qwen"
    "model.api_mode=codex_responses"
    "model.context_length=131072"
    # The key's NAME, not the key. A custom base_url ignores OPENAI_API_KEY
    # unless OPENAI_BASE_URL names the same host, and sends the placeholder
    # "no-key-required" instead, which LiteLLM rejects with a 401.
    "model.key_env=LITELLM_API_KEY"
    "auxiliary.compression.provider=main"

    # Never borrow Claude Code's or Codex's logins. Their refresh tokens are
    # single-use, so sharing one logs the other out, and it would hand
    # Hermes a cloud model that nothing here meant it to have.
    "auth.adopt_external_logins=false"

    # No messaging platforms. Hermes turns a platform on whenever its token
    # is in the environment, and every interactive shell here exports
    # TELEGRAM_BOT_TOKEN (dotfiles 55_secrets.sh sources ~/.secrets/telegram-bot).
    # The session gateway the CLI starts then long-polls the Claude Telegram
    # bot's token and steals its updates ("Conflict: terminated by other
    # getUpdates request"). An explicit false beats the env token.
    "platforms.telegram.enabled=false"
    "platforms.discord.enabled=false"
    "platforms.slack.enabled=false"

    # Every turn runs in the profile's one shared gateway, not in the pane's
    # own process. These names travel with each session from the pane that
    # opened it, so the herdr-push-state plugin reports to the right pane
    # (herdrdev/herdr#5373).
    'terminal.client_env_passthrough=["HERDR_ENV", "HERDR_PANE_ID", "HERDR_SOCKET_PATH"]'

    # A human approves every dangerous command, memory write and skill
    # write until Hermes has earned "smart". In a delegated run that human
    # is Will, through Claude.
    "approvals.mode=manual"
    "memory.memory_enabled=true"
    "memory.write_approval=true"
    "skills.write_approval=true"

    "telemetry.shared_metrics.enabled=false"
    "telemetry.shared_metrics.send=false"
    "$@"
  )

  local s failed=0
  for s in "${settings[@]}"; do
    if ! "${hermes[@]}" config set "${s%%=*}" "${s#*=}" >/dev/null 2>&1; then
      log "  WARNING: [${label}] 'hermes config set ${s%%=*}' failed"
      failed=1
    fi
  done
  # UPPER_SNAKE names go to the profile's .env, not config.yaml.
  if ! "${hermes[@]}" config set LITELLM_API_KEY "$(cat "$key_file")" >/dev/null 2>&1; then
    log "  WARNING: [${label}] could not write the LiteLLM key to the profile's .env"
    failed=1
  fi
  [ "$failed" -eq 0 ] && log "  Hermes profile ${label} configured"
  return "$failed"
}
