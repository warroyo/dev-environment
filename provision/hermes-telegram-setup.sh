#!/usr/bin/env bash
#
# Puts Hermes' lab profile on Telegram, always on (docs/local-ai.md, "Hermes on
# Telegram"). The human half is in the app: @BotFather → /newbot for a bot of
# Hermes' own. Never reuse the Claude bot's token: Telegram allows one
# getUpdates consumer per token, so the two would steal each other's messages.
#
#   ./provision/hermes-telegram-setup.sh
#
# Asks for the token with echo off. HERMES_TELEGRAM_BOT_TOKEN in the
# environment skips the prompt (prefix the command with a space to keep it out
# of ~/.zsh_history). The allow-list defaults to the private chat ids already
# allowed for claude-telegram-bot: a private chat's id is the user's id, so
# that is Will. Set HERMES_TELEGRAM_ALLOWED_USERS (comma separated) to choose.
#
# Writes ~/.secrets/hermes-telegram, then runs configure_hermes, which puts the
# token and allow-list in the lab profile, turns Telegram on and installs the
# gateway as a systemd user service with lingering (needs sudo once).
#
# Re-runnable: run it again to rotate the token or change the allow-list. To
# take Hermes off Telegram, delete ~/.secrets/hermes-telegram, run
# ./provision/local-ai-setup.sh, then `hermes gateway uninstall`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$HOME/.secrets"
SECRETS="$SECRETS_DIR/hermes-telegram"
CLAUDE_BOT_SECRETS="$SECRETS_DIR/telegram-bot"

log()  { printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  die "run this as your normal user, not with sudo (it writes \$HOME/.secrets and your Hermes profile)"
fi
SUDO="sudo"

for c in curl jq; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done

# ---------------------------------------------------------------------------
# Token. Its own variable name: every interactive shell sources ~/.secrets/*,
# and TELEGRAM_BOT_TOKEN there is the Claude bot's.
token="${HERMES_TELEGRAM_BOT_TOKEN:-}"
if [ -z "$token" ]; then
  [ -t 0 ] || die "set HERMES_TELEGRAM_BOT_TOKEN, or run this in a terminal"
  printf "Hermes bot's token from @BotFather (input hidden): "
  read -rs token
  printf '\n'
fi
token="$(printf '%s' "$token" | tr -d '[:space:]')"
[ -n "$token" ] || die "empty token"

claude_token=""
[ -r "$CLAUDE_BOT_SECRETS" ] && \
  claude_token="$(. "$CLAUDE_BOT_SECRETS" && printf '%s' "${TELEGRAM_BOT_TOKEN:-}")"
[ "$token" != "$claude_token" ] || \
  die "that is claude-telegram-bot's token — Hermes needs a bot of its own (@BotFather → /newbot)"

log "Checking the token against Telegram"
# The URL carries the token, so curl reads it as config on stdin: argv shows
# in `ps` to every local user.
me="$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$token" \
        | curl -sS --max-time 20 -K - 2>/dev/null || true)"
[ -n "$me" ] || die "no response from api.telegram.org — check this box's network path"
[ "$(jq -r '.ok' <<<"$me" 2>/dev/null)" = "true" ] || \
  die "Telegram rejected the token: $(jq -r '.description // .' <<<"$me" 2>/dev/null)"
bot="$(jq -r '.result.username' <<<"$me")"
info "authenticated as @${bot}  (t.me/${bot})"

# ---------------------------------------------------------------------------
# Allow-list
users="${HERMES_TELEGRAM_ALLOWED_USERS:-}"
if [ -z "$users" ] && [ -r "$CLAUDE_BOT_SECRETS" ]; then
  # Private chats only (positive ids); a group's id is negative and is no user.
  users="$(. "$CLAUDE_BOT_SECRETS" && printf '%s' "${TELEGRAM_ALLOWED_CHAT_IDS:-}" \
             | tr ' ,' '\n\n' | grep -E '^[0-9]+$' | paste -sd, - || true)"
  [ -n "$users" ] && info "allow-list taken from claude-telegram-bot's private chats"
fi
[ -n "$users" ] || die "no allow-list — set HERMES_TELEGRAM_ALLOWED_USERS to your Telegram user id"
users="$(printf '%s' "$users" | tr ' ' ',' | tr -s ',' | sed 's/^,//; s/,$//')"
for id in ${users//,/ }; do
  case "$id" in ''|*[!0-9]*) die "not a Telegram user id: $id" ;; esac
done

# The allow-list is all that stands between a stranger and a shell on this
# host, so confirm it.
if [ -t 0 ]; then
  printf '\nAllow Telegram user id(s) %s to talk to the lab profile? [Y/n] ' "$users"
  read -r answer
  case "$answer" in [Nn]*) die "aborted — nothing written" ;; esac
fi

# ---------------------------------------------------------------------------
log "Writing $SECRETS"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -e "$SECRETS" ]; then
  cp -p "$SECRETS" "${SECRETS}.bak"
  chmod 600 "${SECRETS}.bak"
  info "previous file kept as ${SECRETS}.bak"
fi
( umask 077
  cat > "$SECRETS" <<EOF
# Written by provision/hermes-telegram-setup.sh — a bearer token lives here.
# Read by configure_hermes (provision/lib/hermes.sh), which copies it into the
# lab profile's .env. Sourced by every interactive shell too, hence the names.
export HERMES_TELEGRAM_BOT_TOKEN='${token}'
export HERMES_TELEGRAM_ALLOWED_USERS='${users}'
EOF
)
chmod 600 "$SECRETS"

# ---------------------------------------------------------------------------
# shellcheck source=lib/hermes.sh
source "${SCRIPT_DIR}/lib/hermes.sh"
log "Configuring Hermes"
configure_hermes || die "configure_hermes reported a problem — see the warnings above"

log "Done. Message @${bot} on your phone; check with:"
info "hermes gateway status"
info "journalctl --user -u 'hermes-gateway*' -n 50"
