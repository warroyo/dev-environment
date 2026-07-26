#!/usr/bin/env bash
#
# Idempotent bootstrap for the Ubuntu server — the sole, always-on Claude
# Code host. Safe to re-run any time; every step checks current state
# before acting.
#
# NOTE on ordering: sshd's bind restriction needs Tailscale's IP address,
# but `tailscale up` is a manual, interactive, one-time step (see
# docs/server-setup.md) that normally happens *after* this script. Run this
# script once before `tailscale up`, then run it again afterward — the
# second run is what actually locks sshd down. Every other step here is a
# no-op on the second run.
set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# ---------------------------------------------------------------------------
log "Updating apt package index"
$SUDO apt-get update -qq

log "Installing base packages"
$SUDO apt-get install -y --no-install-recommends \
  tmux git curl wget ca-certificates gnupg build-essential \
  ripgrep fd-find bat fzf

# eza isn't in Ubuntu's default repos; add its apt repo once.
if ! command -v eza >/dev/null 2>&1; then
  log "Installing eza"
  $SUDO mkdir -p /etc/apt/keyrings
  wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
  echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
    | $SUDO tee /etc/apt/sources.list.d/gierens.list >/dev/null
  $SUDO chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
  $SUDO apt-get update -qq
  $SUDO apt-get install -y eza
else
  log "eza already installed"
fi

# Ubuntu packages fd/bat as fdfind/batcat; symlink to the names everything
# (including dot_zshrc's aliases) expects.
mkdir -p "$HOME/.local/bin"
[ -x "$HOME/.local/bin/fd" ] || ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
[ -x "$HOME/.local/bin/bat" ] || ln -s "$(command -v batcat)" "$HOME/.local/bin/bat"

# ---------------------------------------------------------------------------
log "Installing Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  log "Tailscale already installed"
fi
$SUDO systemctl enable --now tailscaled

# ---------------------------------------------------------------------------
log "Installing Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | $SUDO sh
else
  log "Docker already installed"
fi
$SUDO usermod -aG docker "$USER" || true
$SUDO systemctl enable --now docker

# ---------------------------------------------------------------------------
log "Installing chezmoi"
if ! command -v chezmoi >/dev/null 2>&1; then
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
else
  log "chezmoi already installed"
fi

# ---------------------------------------------------------------------------
log "Installing tmux plugin manager (tpm)"
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ ! -d "$TPM_DIR" ]; then
  git clone -q https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  git -C "$TPM_DIR" pull -q --ff-only
fi

# ---------------------------------------------------------------------------
# gluetun: isolates the second, unrelated OpenVPN environment in its own
# network namespace so it can never contend with Tailscale for the box's
# default route (constraint: Tailscale and this OpenVPN client must never
# share a routing table). claude-env-shell shares gluetun's network stack
# so Claude Code's traffic for that environment actually goes through the
# tunnel; it's reached via `docker exec` from the claude-env tmux session,
# never mixed into the main claude-main session.
# ---------------------------------------------------------------------------
log "Setting up gluetun for the second (unrelated) OpenVPN environment"
GLUETUN_DIR="/opt/claude-env-vpn"
$SUDO mkdir -p "${GLUETUN_DIR}/config"
$SUDO chown -R "$USER":"$USER" "$GLUETUN_DIR"

cat >"${GLUETUN_DIR}/docker-compose.yml" <<'EOF'
# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: claude-env-vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=openvpn
      - OPENVPN_CUSTOM_CONFIG=/gluetun/client-env.ovpn
    volumes:
      - ./config:/gluetun
    restart: unless-stopped

  claude-env-shell:
    image: node:20-bookworm-slim
    container_name: claude-env-shell
    network_mode: "service:gluetun"
    depends_on:
      - gluetun
    volumes:
      - claude-env-workspace:/workspace
      - claude-env-config:/root/.claude
    working_dir: /workspace
    command: sleep infinity
    restart: unless-stopped

volumes:
  claude-env-workspace:
  claude-env-config:
EOF

if [ -f "${GLUETUN_DIR}/config/client-env.ovpn" ]; then
  (cd "$GLUETUN_DIR" && docker compose up -d)
  if docker ps --format '{{.Names}}' | grep -qx claude-env-shell; then
    if ! docker exec claude-env-shell sh -c 'command -v claude' >/dev/null 2>&1; then
      log "Installing Claude Code CLI inside claude-env-shell"
      docker exec claude-env-shell npm install -g @anthropic-ai/claude-code
    fi
  fi
else
  log "No client-env.ovpn in ${GLUETUN_DIR}/config yet — drop it there, then run:"
  log "  (cd ${GLUETUN_DIR} && docker compose up -d)"
  log "See docs/server-setup.md."
fi

# ---------------------------------------------------------------------------
log "Writing claude-tmux systemd service"
UNIT_PATH="/etc/systemd/system/claude-tmux.service"
cat <<EOF | $SUDO tee "$UNIT_PATH" >/dev/null
[Unit]
Description=Persistent tmux session (claude-main) running Claude Code
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=forking
User=${USER}
Environment=HOME=${HOME}
RemainAfterExit=yes
ExecStart=/usr/bin/tmux new-session -d -s claude-main claude
ExecStop=/usr/bin/tmux kill-session -t claude-main
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable claude-tmux.service
if ! $SUDO systemctl is-active --quiet claude-tmux.service; then
  $SUDO systemctl start claude-tmux.service
else
  log "claude-tmux.service already running"
fi

# ---------------------------------------------------------------------------
# sshd bind restriction: Tailscale interface + LAN interface only, never
# WAN. This is what lets both the Tailscale path (personal Air) and the
# OpenVPN-to-LAN path (work laptop) reach the box, while it has zero SSH
# surface on the public internet.
# ---------------------------------------------------------------------------
log "Restricting sshd bind addresses"
TS_IP="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null || true)"
LAN_IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
LAN_IP="$(ip -o -4 addr show "$LAN_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-listen-addresses.conf"

if [ -z "$TS_IP" ]; then
  log "WARNING: Tailscale has no IP yet. Run 'sudo tailscale up', then re-run this script to lock down sshd. Leaving sshd as-is for now."
elif [ -z "$LAN_IP" ]; then
  log "WARNING: couldn't determine a LAN IP on ${LAN_IFACE}. Leaving sshd as-is for now."
else
  NEW_CONF="# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
# Binds sshd to the Tailscale and LAN interfaces only; never WAN.
ListenAddress ${TS_IP}
ListenAddress ${LAN_IP}
"
  if [ ! -f "$SSHD_DROPIN" ] || [ "$(cat "$SSHD_DROPIN" 2>/dev/null)" != "$NEW_CONF" ]; then
    printf '%s' "$NEW_CONF" | $SUDO tee "$SSHD_DROPIN" >/dev/null
    $SUDO sshd -t
    $SUDO systemctl reload ssh
    log "sshd now bound to ${LAN_IP} (LAN) and ${TS_IP} (Tailscale) only"
  else
    log "sshd bind restriction already up to date"
  fi
fi

log "Server bootstrap complete. See docs/server-setup.md for remaining manual steps."
