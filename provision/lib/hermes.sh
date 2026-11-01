#!/usr/bin/env bash
# Hermes Agent on the local model, in two profiles.
#
#   ensure_hermes                 installs the CLI (stable channel)
#   install_hermes_sandbox_net    the Docker network the restricted profile's
#                                 commands run in, and the firewall rules that
#                                 keep it on the internet only
#   install_hermes_work_prune     a daily timer that deletes delegated job
#                                 folders in ~/hermes-work once they go idle
#   configure_hermes             sets up both profiles on LiteLLM, one
#                                 `hermes config set` at a time
#   configure_hermes_telegram     the lab profile on its own Telegram bot, as
#                                 an always-on gateway service (only once
#                                 provision/hermes-telegram-setup.sh has
#                                 written ~/.secrets/hermes-telegram)
#   install_hermes_shared_skills  links the lab profile's share of the Claude
#                                 Code skills where Hermes scans for them
#   install_hermes_soul_rules     Will's standing rules in the lab profile's
#                                 SOUL.md, loaded in every session
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
#     container's client-lab traffic straight down the tunnel, because routing
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
# it covers tun0 (the client lab's ranges are private) and the host's own
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

# install_hermes_work_prune
#
# A daily timer that deletes old delegated jobs. Each job Claude hands to
# Hermes gets ~/hermes-work/<topic>/ (brief, result, summary, scripts), and
# nothing else ever removes them. A job folder goes once nothing in it has
# changed for $HERMES_WORK_RETENTION_DAYS, so a job still being written to is
# never touched. Hermes' own ~/.hermes/cache/scratch, where it drops scripts
# when not told otherwise, is pruned file by file on the same rule.
#
# Runs as Will, not root: it only ever deletes his own files.
HERMES_WORK_DIR="${HERMES_WORK_DIR:-$HOME/hermes-work}"
HERMES_WORK_RETENTION_DAYS="${HERMES_WORK_RETENTION_DAYS:-14}"

install_hermes_work_prune() {
  local script_path=/usr/local/bin/hermes-work-prune
  local svc_path=/etc/systemd/system/hermes-work-prune.service
  local timer_path=/etc/systemd/system/hermes-work-prune.timer
  local tmp changed=0

  mkdir -p "$HERMES_WORK_DIR"

  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
#!/bin/sh
# Managed by dev-environment/provision/lib/hermes.sh — do not edit by hand.
# Deletes Hermes job folders in ${HERMES_WORK_DIR} with nothing changed in
# ${HERMES_WORK_RETENTION_DAYS} days, and scratch files older than that.
#   hermes-work-prune [--dry-run]
set -eu
WORK=${HERMES_WORK_DIR}
SCRATCH=${HOME}/.hermes/cache/scratch
DAYS=${HERMES_WORK_RETENTION_DAYS}
DRY=0
[ "\${1:-}" = "--dry-run" ] && DRY=1

drop() {
  if [ "\$DRY" -eq 1 ]; then echo "would delete \$1"; else rm -rf -- "\$1"; fi
}

for d in "\$WORK"/*/; do
  [ -d "\$d" ] || continue
  # Anything modified inside the retention window keeps the whole job.
  [ -n "\$(find "\$d" -mtime -"\$DAYS" -print -quit)" ] && continue
  drop "\$d"
done

if [ -d "\$SCRATCH" ]; then
  find "\$SCRATCH" -type f -mtime +"\$DAYS" | while IFS= read -r f; do drop "\$f"; done
fi
exit 0
EOF
  if ! $SUDO cmp -s "$tmp" "$script_path" 2>/dev/null; then
    $SUDO install -m 755 "$tmp" "$script_path"
  fi

  cat >"$tmp" <<EOF
# Managed by dev-environment/provision/lib/hermes.sh — do not edit by hand.
[Unit]
Description=Delete Hermes job folders untouched for ${HERMES_WORK_RETENTION_DAYS} days

[Service]
Type=oneshot
User=${USER}
Environment=HOME=${HOME}
ExecStart=${script_path}
EOF
  if ! $SUDO cmp -s "$tmp" "$svc_path" 2>/dev/null; then
    $SUDO install -m 644 "$tmp" "$svc_path"
    changed=1
  fi

  cat >"$tmp" <<EOF
# Managed by dev-environment/provision/lib/hermes.sh — do not edit by hand.
[Unit]
Description=Daily prune of ${HERMES_WORK_DIR}

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if ! $SUDO cmp -s "$tmp" "$timer_path" 2>/dev/null; then
    $SUDO install -m 644 "$tmp" "$timer_path"
    changed=1
  fi
  rm -f "$tmp"

  if [ "$changed" -eq 1 ]; then $SUDO systemctl daemon-reload; fi
  $SUDO systemctl enable --now hermes-work-prune.timer >/dev/null 2>&1 || \
    { log "  WARNING: could not enable hermes-work-prune.timer"; return 1; }
  log "  ${HERMES_WORK_DIR} pruned daily (jobs idle ${HERMES_WORK_RETENTION_DAYS}+ days)"
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

  # Set in the same pass as the rest, so a re-run never flips Telegram off
  # and back on under a running gateway.
  local lab_telegram=false
  [ -s "$HERMES_TELEGRAM_SECRETS" ] && lab_telegram=true
  HERMES_PROFILE_TELEGRAM="$lab_telegram" \
  _hermes_configure_profile "" "$HOME/.secrets/litellm/hermes-lab.key" \
    "terminal.backend=local" \
    'approvals.deny=["ssh *-admin*", "ansible *", "*ansible-playbook*", "*ansible/play*"]' \
    "skills.external_dirs=[\"${HERMES_SHARED_SKILLS_DIR}\"]" \
    || failed=1
  install_hermes_shared_skills || failed=1
  install_hermes_soul_rules || failed=1

  # terminal.cwd is the host inbox, mounted into the container as its working
  # directory. The TUI sends terminal.cwd to the gateway as the session cwd,
  # and the gateway refuses one that does not exist on the host
  # ("Error: invalid_params", field=cwd), so a container-only path such as
  # /inbox stops the TUI starting. The docker backend in turn drops a /home/...
  # cwd as a host path and falls back to /root, which a host-user container
  # cannot enter. Mounting the cwd satisfies both; /inbox stays as the path
  # briefs refer to.
  mkdir -p "$HERMES_INBOX_DIR"
  _hermes_configure_profile "$HERMES_RESTRICTED_PROFILE" "$HOME/.secrets/litellm/hermes-restricted.key" \
    "terminal.backend=docker" \
    "terminal.container_persistent=false" \
    "terminal.container_memory=4096" \
    "terminal.container_cpu=2" \
    "terminal.docker_mount_cwd_to_workspace=true" \
    "terminal.docker_extra_args=[\"--network\", \"${HERMES_SANDBOX_NET}\"]" \
    "terminal.docker_volumes=[\"${HERMES_INBOX_DIR}:/inbox\"]" \
    "terminal.docker_run_as_host_user=true" \
    "terminal.cwd=${HERMES_INBOX_DIR}" \
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
  configure_hermes_telegram || failed=1
  return "$failed"
}

# install_hermes_shared_skills
#
# The lab profile's share of the Claude Code skills, so a session nobody
# briefed (Telegram, a pane started by hand) still knows where the lab's state
# lives and how to log in to the client lab. Hermes scans the folder through
# skills.external_dirs, set in configure_hermes.
#
# A curated folder of links rather than ~/.claude/skills itself: most of those
# are about Claude's own workflow (handoff, log-session, hermes), or are for
# coding and writing, which stay with Claude and Codex. lab-creds is in because
# a Telegram session can already read ~/.lab.env (see configure_hermes_telegram);
# the skill only teaches it to use that properly.
#
# Each link points at the ~/.claude/skills entry, so a skill edited or
# re-pointed for Claude changes for Hermes too. External dirs are not
# read-only to Hermes, but skills.write_approval=true puts every skill edit in
# front of Will first.
HERMES_SHARED_SKILLS_DIR="${HERMES_SHARED_SKILLS_DIR:-$HOME/.local/share/hermes-skills}"
HERMES_SHARED_SKILLS=(homelab second-brain lab-creds)

install_hermes_shared_skills() {
  local name src link failed=0
  mkdir -p "$HERMES_SHARED_SKILLS_DIR"
  for name in "${HERMES_SHARED_SKILLS[@]}"; do
    src="$HOME/.claude/skills/${name}"
    link="${HERMES_SHARED_SKILLS_DIR}/${name}"
    if [ ! -f "$src/SKILL.md" ]; then
      log "  WARNING: ${src}/SKILL.md not found — Hermes will not get the ${name} skill"
      failed=1
      continue
    fi
    if [ -L "$link" ]; then
      [ "$(readlink "$link")" = "$src" ] || ln -sfn "$src" "$link"
    elif [ -e "$link" ]; then
      log "  WARNING: ${link} exists and is not a symlink — leaving it alone"
      failed=1
    else
      ln -s "$src" "$link"
    fi
  done
  # Drop links for skills no longer on the list.
  for link in "$HERMES_SHARED_SKILLS_DIR"/*; do
    [ -L "$link" ] || continue
    case " ${HERMES_SHARED_SKILLS[*]} " in
      *" $(basename "$link") "*) ;;
      *) rm -f "$link" ;;
    esac
  done
  [ "$failed" -eq 0 ] && log "  Hermes lab profile shares skills: ${HERMES_SHARED_SKILLS[*]}"
  return "$failed"
}

# install_hermes_soul_rules
#
# Will's standing rules, appended to the lab profile's SOUL.md: the one context
# file Hermes loads in every session, wherever it starts. AGENTS.md would only
# load in sessions whose working directory holds one, and a Telegram session
# has no fixed one. This is Hermes' counterpart of ~/.claude/CLAUDE.md and
# ~/.codex/AGENTS.md.
#
# Only the block between the markers is managed. Hermes seeds the persona text
# above it and Will may edit that; a re-run replaces the block and nothing else.
HERMES_SOUL_BEGIN='<!-- dev-environment: managed block, edit provision/lib/hermes.sh -->'
HERMES_SOUL_END='<!-- dev-environment: end -->'

install_hermes_soul_rules() {
  local soul="$HOME/.hermes/SOUL.md" tmp
  tmp="$(mktemp)"
  if [ -f "$soul" ]; then
    # Everything outside the old block, trailing blank lines trimmed.
    awk -v b="$HERMES_SOUL_BEGIN" -v e="$HERMES_SOUL_END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip' "$soul" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$tmp"
    printf '\n\n' >>"$tmp"
  fi
  cat >>"$tmp" <<EOF
${HERMES_SOUL_BEGIN}
## Will's lab: standing rules

- Before answering anything about the home lab, use the \`homelab\` skill. It
  reads the current state from ~/second-brain/topics/homelab.md. Do not
  answer lab questions from general knowledge alone.
- For the client lab (vCenter, the Supervisor, VCF Automation, Cloud
  Foundry; hostnames in ~/.lab.env), use the \`lab-creds\` skill for logins. Never put a
  credential in a reply, a note or a file.
- On live machines, only query and troubleshoot, through the no-sudo \`agent\`
  account. Do not install packages, edit config or change state by hand. A fix
  goes into ~/workspace/dev-environment as code, and Will applies it.
- The work laptop is out of scope. Never propose anything that involves it.
- ~/second-brain is Will's vault. Save notes only through the \`second-brain\`
  skill, and never edit anything in its entries/ folder.
- Coding and code review stay with Claude and Codex. If asked for either,
  say so.
${HERMES_SOUL_END}
EOF
  if cmp -s "$tmp" "$soul" 2>/dev/null; then
    rm -f "$tmp"
    log "  Hermes SOUL.md rules already current"
    return 0
  fi
  [ -f "$soul" ] && chmod --reference="$soul" "$tmp"
  mv "$tmp" "$soul"
  log "  Hermes SOUL.md rules written"
}

# configure_hermes_telegram
#
# The lab profile answers on Telegram, always on: the phone's way to talk to
# Hermes directly. Its own bot, never the Claude bot's token, because Telegram
# allows one getUpdates consumer per token. Will chose the lab profile over
# restricted on 2026-10-26, knowing what that hands a Telegram session:
#
#   - Approvals (approvals.mode=manual) cover only the commands Hermes flags
#     as dangerous, and come to the chat as buttons. Reading ~/.lab.env is
#     not dangerous, so whoever holds the Telegram session can read it.
#   - The allow-list is the whole gate. TELEGRAM_ALLOWED_USERS is Will's user
#     id only, and strangers get no reply at all (unauthorized_dm_behavior
#     ignore, not the default pairing code), the same as claude-telegram-bot.
#
# The gateway is Hermes' own systemd user service (`hermes gateway install`,
# which owns the unit), with lingering on so it starts at boot rather than at
# login. It is also the profile's shared gateway, so lab sessions in herdr
# panes run their turns in it too.
#
# Without ~/.secrets/hermes-telegram this does nothing: Telegram stays off
# (configure_hermes sets that) and no service is installed.
HERMES_TELEGRAM_SECRETS="${HERMES_TELEGRAM_SECRETS:-$HOME/.secrets/hermes-telegram}"

configure_hermes_telegram() {
  if [ ! -s "$HERMES_TELEGRAM_SECRETS" ]; then
    log "  Hermes is not on Telegram (no ${HERMES_TELEGRAM_SECRETS}; provision/hermes-telegram-setup.sh writes it)"
    return 0
  fi

  # A subshell, so the token never lands in this script's environment.
  local token users
  token="$(. "$HERMES_TELEGRAM_SECRETS" && printf '%s' "${HERMES_TELEGRAM_BOT_TOKEN:-}")"
  users="$(. "$HERMES_TELEGRAM_SECRETS" && printf '%s' "${HERMES_TELEGRAM_ALLOWED_USERS:-}")"
  if [ -z "$token" ] || [ -z "$users" ]; then
    log "  WARNING: ${HERMES_TELEGRAM_SECRETS} lacks the token or the allow-list — re-run provision/hermes-telegram-setup.sh"
    return 1
  fi

  local s failed=0
  # UPPER_SNAKE names go to the profile's .env (~/.hermes/.env, mode 600).
  for s in "TELEGRAM_BOT_TOKEN=${token}" "TELEGRAM_ALLOWED_USERS=${users}" \
           "unauthorized_dm_behavior=ignore"; do
    if ! "$HERMES_BIN" config set "${s%%=*}" "${s#*=}" >/dev/null 2>&1; then
      log "  WARNING: [lab] 'hermes config set ${s%%=*}' failed"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || return 1

  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
    if $SUDO loginctl enable-linger "$USER"; then
      log "  lingering on for ${USER}: user services start at boot"
    else
      log "  WARNING: 'loginctl enable-linger ${USER}' failed — the gateway will only run while you are logged in"
    fi
  fi

  # --if-missing leaves an installed unit alone; Hermes refreshes its own unit
  # on start and on `hermes update`.
  if ! "$HERMES_BIN" gateway install --if-missing --start-on-login --no-start-now >/dev/null 2>&1; then
    log "  WARNING: 'hermes gateway install' failed"
    return 1
  fi

  # Stop everything, then start the service, so it picks up a new token or
  # allow-list. Not `gateway restart`: with the unit installed but inactive and
  # a gateway that a CLI session started on its own still running, restart
  # sends that gateway a graceful-restart signal and waits for a supervisor to
  # relaunch it. Nothing supervises it, so the wait runs to Hermes' drain
  # timeout (about 3 minutes, silently, since output goes to /dev/null) before
  # the unit comes up. Plain `stop` would not help either: with a unit
  # installed it stops only the unit and leaves the stray gateway running.
  # --all stops the unit AND kills every gateway process; one host gateway
  # serves both profiles, so nothing else is lost. A session running in a
  # herdr pane drops its turn and reconnects to the new gateway.
  "$HERMES_BIN" gateway stop --all >/dev/null 2>&1 || true
  if ! timeout 120 "$HERMES_BIN" gateway start >/dev/null 2>&1; then
    log "  WARNING: 'hermes gateway start' failed or timed out — check 'hermes gateway status'"
    return 1
  fi
  log "  Hermes lab profile on Telegram, gateway running as a user service"
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

    # No messaging platforms, except Telegram on the lab profile once it has
    # a bot of its own (configure_hermes_telegram). Hermes turns a platform
    # on whenever its token is in the environment, and every interactive
    # shell here exports TELEGRAM_BOT_TOKEN (dotfiles 55_secrets.sh sources
    # ~/.secrets/telegram-bot). The session gateway the CLI starts then
    # long-polls the Claude Telegram bot's token and steals its updates
    # ("Conflict: terminated by other getUpdates request"). An explicit false
    # beats the env token; with true, the profile's .env token wins over the
    # shell's, because Hermes loads .env with override.
    "platforms.telegram.enabled=${HERMES_PROFILE_TELEGRAM:-false}"
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
