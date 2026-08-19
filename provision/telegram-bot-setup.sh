#!/usr/bin/env bash
#
# One-shot configurator for the Telegram bot (docs/server-setup.md §9).
#
# Everything on the Telegram side that a human must do is done in the app —
# @BotFather → /newbot, then pressing Start in the chat. Everything after that
# is mechanical: validate the token, find out which chat id pressed Start,
# write ~/.secrets/telegram-bot with the right permissions, enable the unit.
# This script is that mechanical half.
#
#   TELEGRAM_BOT_TOKEN=123456:ABC... ./provision/telegram-bot-setup.sh
#
# The token comes from the environment rather than an argument so it never
# lands in shell history or in another user's `ps` output. Prefix the command
# with a space (or export it) and it stays out of ~/.zsh_history too. If the
# variable is unset and this is a terminal, the script asks for it with echo
# off instead of failing.
#
# Chat ids are DISCOVERED by default: the script long-polls getUpdates and
# waits for you to message the bot, which is the only way to learn your own id
# (a bot cannot message you first, so with no message from you there is no
# chat to name). Set TELEGRAM_ALLOWED_CHAT_IDS yourself to skip that and go
# straight to writing the file:
#
#   TELEGRAM_BOT_TOKEN=... TELEGRAM_ALLOWED_CHAT_IDS="123456789 987654321" \
#     ./provision/telegram-bot-setup.sh
#
# Re-runnable: run it again to rotate the token or add an id. The previous
# file is kept as ~/.secrets/telegram-bot.bak.
set -euo pipefail

SECRETS_DIR="$HOME/.secrets"
SECRETS="${TELEGRAM_SECRETS_FILE:-$SECRETS_DIR/telegram-bot}"
UNIT="claude-telegram-bot.service"
UNIT_PATH="/etc/systemd/system/${UNIT}"
# How long to wait for you to open the app and send a message. Long enough to
# find the chat, short enough that a forgotten terminal gives up on its own.
DISCOVER_TIMEOUT="${TELEGRAM_DISCOVER_TIMEOUT:-180}"

log()  { printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  # The secrets file belongs to the user the bot's unit runs as; under sudo,
  # $HOME is /root and the file would be written where the bot never looks.
  die "run this as your normal user, not with sudo (it writes \$HOME/.secrets)"
fi
SUDO="sudo"

for c in curl jq; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done

# ---------------------------------------------------------------------------
# Token
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  if [ -t 0 ]; then
    printf 'Bot token from @BotFather (input hidden): '
    read -rs TELEGRAM_BOT_TOKEN
    printf '\n'
  else
    die "set TELEGRAM_BOT_TOKEN — see docs/server-setup.md §9 for /newbot"
  fi
fi
# Trim whitespace: pasting from the BotFather chat usually brings a trailing
# space or newline along, and Telegram answers 404 for the resulting URL,
# which reads like a wrong token rather than a stray byte.
TELEGRAM_BOT_TOKEN="$(printf '%s' "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')"
[ -n "$TELEGRAM_BOT_TOKEN" ] || die "empty token"

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

log "Checking the token against Telegram"
# getMe is the cheapest proof that the token is real and that this box can
# reach api.telegram.org at all — worth separating, because a routing problem
# and a mistyped token otherwise both surface as "the bot does nothing".
me="$(curl -sS --max-time 20 "${API}/getMe" 2>/dev/null || true)"
[ -n "$me" ] || die "no response from api.telegram.org — check this box's network path"
if [ "$(jq -r '.ok' <<<"$me" 2>/dev/null)" != "true" ]; then
  die "Telegram rejected the token: $(jq -r '.description // .' <<<"$me" 2>/dev/null)"
fi
BOT_USERNAME="$(jq -r '.result.username' <<<"$me")"
info "authenticated as @${BOT_USERNAME}  (t.me/${BOT_USERNAME})"

# ---------------------------------------------------------------------------
# Chat ids
ALLOWED="${TELEGRAM_ALLOWED_CHAT_IDS:-}"

# Anything already polling this token would take the updates instead of us:
# Telegram allows exactly one getUpdates consumer and answers the second with
# 409 Conflict. The running bot is the likely one, so stop it for the duration
# and put it back however this script exits.
BOT_WAS_ACTIVE=0
restore_bot() {
  [ "$BOT_WAS_ACTIVE" -eq 1 ] || return 0
  $SUDO systemctl start "$UNIT" >/dev/null 2>&1 || true
}
if [ -z "$ALLOWED" ] && systemctl is-active --quiet "$UNIT" 2>/dev/null; then
  log "Stopping $UNIT while we poll for updates"
  info "only one client may long-poll a bot token at a time"
  BOT_WAS_ACTIVE=1
  trap restore_bot EXIT
  $SUDO systemctl stop "$UNIT"
fi

if [ -z "$ALLOWED" ]; then
  # A webhook, if one is set, disables getUpdates entirely — it answers 409
  # forever and no amount of messaging the bot changes that. This bot polls,
  # so a webhook here is always leftover configuration.
  hook="$(curl -sS --max-time 20 "${API}/getWebhookInfo" 2>/dev/null || true)"
  if [ -n "$(jq -r '.result.url // ""' <<<"$hook" 2>/dev/null)" ]; then
    log "Deleting the webhook set on this bot (it blocks getUpdates)"
    curl -sS --max-time 20 "${API}/deleteWebhook" >/dev/null || true
  fi

  log "Waiting for a message so we can learn your chat id"
  info "open t.me/${BOT_USERNAME} on your phone, press Start, send anything"
  info "(giving up after ${DISCOVER_TIMEOUT}s)"

  deadline=$(( $(date +%s) + DISCOVER_TIMEOUT ))
  found=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # No `offset` parameter on purpose: acknowledging the updates here would
    # consume them, and the bot's own first poll should still see the /start.
    updates="$(curl -sS --max-time 40 -G "${API}/getUpdates" \
                 --data-urlencode 'timeout=25' 2>/dev/null || true)"
    [ -n "$updates" ] || continue
    if [ "$(jq -r '.ok' <<<"$updates" 2>/dev/null)" != "true" ]; then
      die "getUpdates failed: $(jq -r '.description // .' <<<"$updates" 2>/dev/null)"
    fi
    # Match the chat object wherever it sits: a plain message, an edit, a
    # channel post and a my_chat_member update all nest it differently, and
    # which one arrives depends on how you happened to poke the bot.
    found="$(jq -r '[.. | objects | select(has("chat")) | .chat]
                    | unique_by(.id)
                    | .[] | "\(.id)\t\(.type)\t\(.username // .title // .first_name // "?")"' \
                <<<"$updates" 2>/dev/null || true)"
    [ -n "$found" ] && break
  done
  [ -n "$found" ] || die "no message arrived — re-run once you have messaged @${BOT_USERNAME}"

  printf '\n'
  printf '    %-14s %-9s %s\n' 'CHAT ID' 'TYPE' 'WHO'
  while IFS=$'\t' read -r id type who; do
    printf '    %-14s %-9s %s\n' "$id" "$type" "$who"
  done <<<"$found"
  ALLOWED="$(cut -f1 <<<"$found" | tr '\n' ' ' | sed 's/ *$//')"

  # The allow-list is the entire security model, so confirm it rather than
  # assuming every chat that turned up should be able to run claude-open.
  if [ -t 0 ]; then
    printf '\nAllow these chat ids? [Y/n/edit] '
    read -r answer
    case "$answer" in
      [Nn]*) die "aborted — nothing written" ;;
      [Ee]*)
        printf 'Chat ids to allow (space separated): '
        read -r ALLOWED
        ;;
    esac
  fi
fi

ALLOWED="$(printf '%s' "$ALLOWED" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//')"
[ -n "$ALLOWED" ] || die "empty allow-list — the bot would accept commands from anyone"
for id in $ALLOWED; do
  case "$id" in
    ''|*[!0-9-]*) die "not a chat id: $id" ;;
  esac
done

# ---------------------------------------------------------------------------
log "Writing $SECRETS"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -e "$SECRETS" ]; then
  cp -p "$SECRETS" "${SECRETS}.bak"
  chmod 600 "${SECRETS}.bak"
  info "previous file kept as ${SECRETS}.bak"
fi
# umask before creation, not chmod after: for the moment between the two the
# file would otherwise be readable by anyone on the box, token included.
( umask 077
  cat > "$SECRETS" <<EOF
# Written by provision/telegram-bot-setup.sh — a bearer token lives here.
# Sourced by 55_secrets.sh for interactive shells and read directly by
# claude-telegram-bot, which runs under systemd with no shell.
export TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN}'
export TELEGRAM_ALLOWED_CHAT_IDS='${ALLOWED}'
EOF
)
chmod 600 "$SECRETS"
info "allow-list: ${ALLOWED}"

# ---------------------------------------------------------------------------
if [ -f "$UNIT_PATH" ]; then
  log "Enabling and restarting $UNIT"
  trap - EXIT                 # the restart below supersedes restore_bot
  $SUDO systemctl enable "$UNIT" >/dev/null 2>&1 || true
  if $SUDO systemctl restart "$UNIT"; then
    sleep 2
    if systemctl is-active --quiet "$UNIT"; then
      info "running — say /cc_ls to @${BOT_USERNAME} to test it"
    else
      die "$UNIT started then died — journalctl -u claude-telegram-bot -n 50"
    fi
  else
    die "$UNIT failed to start — journalctl -u claude-telegram-bot -n 50"
  fi
else
  log "No $UNIT yet"
  info "run ./provision/server-bootstrap.sh — it writes the unit and, now that"
  info "$SECRETS exists, enables it"
fi
