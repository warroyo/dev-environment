#!/usr/bin/env bash
# Idempotent bootstrap for a lab TARGET — a machine agents on the server SSH
# into, not one they run on (the EVO-X2 model server, a future Plex box).
# Ubuntu/Debian only. Safe to re-run any time.
#
# Self-contained on purpose: a target never clones this repo or applies the
# dotfiles, so copy the script over and run it there.
#
#   scp provision/lab-target-bootstrap.sh <you>@<lan-ip>:
#   ssh -t <you>@<lan-ip> sudo ./lab-target-bootstrap.sh
#
# What it does:
#   1. Installs Tailscale and joins the tailnet with Tailscale SSH on and the
#      target's tags (LAB_TAGS, default tag:lab).
#   2. Creates the `agent` account: no password, no sudo, can read the journal
#      and /var/log, and can keep user services running after logout.
#   3. Turns off password login to sshd, but only once the admin account has
#      an authorized key, so the LAN path stays open as a fallback.
#
# Who may SSH in as which account is decided by policy/tailnet.hujson, not
# here. See docs/lab-access.md.
#
# Environment:
#   LAB_TAGS           comma-separated tags (default: tag:lab). The model
#                      server during build-out: tag:lab,tag:inference
#   TAILSCALE_AUTHKEY  optional; without it `tailscale up` prints a login URL
#   LAB_AGENT_USER     the agent account's name (default: agent)
#   LAB_KEEP_PASSWORD  set to 1 to leave sshd's password login alone
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }
warn() { printf '  WARNING: %s\n' "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

TAGS="${LAB_TAGS:-tag:lab}"
AGENT_USER="${LAB_AGENT_USER:-agent}"
# The human who ran sudo. Their authorized_keys gate the sshd lockdown below.
ADMIN_USER="${SUDO_USER:-}"

# ---------------------------------------------------------------------------
# 1. Tailscale, with Tailscale SSH and the target's tags
# ---------------------------------------------------------------------------
log "Installing Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "  already installed"
fi
systemctl enable --now tailscaled

# Tags as tailscale reports them, one per line, for comparing against $TAGS.
current_tags() {
  tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["Self"].get("Tags") or []))'
}

missing_tags() {
  local have want
  have="$(current_tags)"
  for want in ${TAGS//,/ }; do
    grep -qxF "$want" <<<"$have" || return 0
  done
  return 1
}

log "Joining the tailnet with Tailscale SSH and tags ${TAGS}"
if ! tailscale status >/dev/null 2>&1; then
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    tailscale up --authkey="${TAILSCALE_AUTHKEY}" --ssh --advertise-tags="${TAGS}"
  else
    # Interactive: prints a login URL and waits for it.
    tailscale up --ssh --advertise-tags="${TAGS}"
  fi
else
  # `set` changes one preference and leaves the rest alone.
  tailscale set --ssh
  if missing_tags; then
    # Tags have no `set` flag. `up` refuses, rather than resets, when the
    # machine has other non-default preferences, so a failure here is safe:
    # it prints the full command it wants.
    if ! tailscale up --ssh --advertise-tags="${TAGS}"; then
      warn "could not apply tags ${TAGS}. Re-run the command tailscale printed"
      warn "above, or set them in the admin console: Machines -> this host ->"
      warn "Edit ACL tags."
    fi
  fi
fi
echo "  tags now: $(current_tags | paste -sd, -)"

# ---------------------------------------------------------------------------
# 2. The agent account
# ---------------------------------------------------------------------------
log "Creating the ${AGENT_USER} account"
if id "$AGENT_USER" >/dev/null 2>&1; then
  echo "  already exists"
else
  useradd --create-home --shell /bin/bash --comment "Lab agent, no sudo" "$AGENT_USER"
fi
# Locked password: the only way in is Tailscale SSH, which needs no password
# or key on this side. Re-locking an already-locked account is a no-op.
passwd --lock "$AGENT_USER" >/dev/null
# Read access to logs, nothing more. sudo is deliberately not one of these.
for group in systemd-journal adm; do
  if getent group "$group" >/dev/null; then
    usermod --append --groups "$group" "$AGENT_USER"
  fi
done
# User services the agent starts keep running after its SSH session ends.
loginctl enable-linger "$AGENT_USER"

# ---------------------------------------------------------------------------
# 3. sshd: keys only
# ---------------------------------------------------------------------------
# Tailscale SSH answers port 22 on the tailnet address only, so sshd still
# serves the LAN. That is the fallback when Tailscale is down, and it should
# not take passwords. The drop-in sorts before Ubuntu's 50-cloud-init.conf,
# and sshd keeps the first value it reads, so this one wins.
DROPIN=/etc/ssh/sshd_config.d/10-lab-target.conf

log "Restricting sshd to key logins"
if [ "${LAB_KEEP_PASSWORD:-0}" = 1 ]; then
  echo "  skipped: LAB_KEEP_PASSWORD=1"
elif [ -z "$ADMIN_USER" ] || [ ! -s "$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys" ]; then
  warn "skipped: ${ADMIN_USER:-the admin user} has no ~/.ssh/authorized_keys,"
  warn "so turning off passwords would leave no LAN way in. Add a key from the"
  warn "server (ssh-copy-id <you>@<lan-ip>), then re-run this script."
else
  cat >"${DROPIN}.new" <<'EOF'
# Managed by dev-environment provision/lab-target-bootstrap.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  mv "${DROPIN}.new" "$DROPIN"
  if sshd -t; then
    systemctl try-reload-or-restart ssh
    echo "  password login off"
  else
    rm -f "$DROPIN"
    warn "sshd rejected the config; removed ${DROPIN} and left sshd as it was"
  fi
fi

log "Done. From the server:"
cat <<EOF
  lab-ssh-config                  # regenerate the ssh aliases from tailnet tags
  ssh $(hostname) 'journalctl -n 5'      # as ${AGENT_USER}
  ssh $(hostname)-admin 'sudo -v'        # as you; first use opens a browser check
EOF
