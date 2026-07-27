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
#
# Docker commands here are run via sudo on purpose: `usermod -aG docker`
# below does not affect the *current* shell session, so on a first run the
# invoking user is not yet an effective member of the docker group.
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
# zsh: the shell dot_zshrc.tmpl targets — without it the server never reads
#      any of this repo's shell config.
# mosh: the *server* side (mosh-server) is required for the clients' mosh to
#      work at all.
# zsh-autosuggestions / zsh-syntax-highlighting: without these (and starship
# below) a fresh zsh gives you the bare `hostname%` default prompt, which is
# a downgrade from Ubuntu's stock bash.
$SUDO apt-get install -y --no-install-recommends \
  zsh zsh-autosuggestions zsh-syntax-highlighting \
  tmux git curl wget ca-certificates gnupg build-essential \
  mosh ripgrep fd-find bat fzf

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
if [ ! -e "$HOME/.local/bin/fd" ] && command -v fdfind >/dev/null 2>&1; then
  ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi
if [ ! -e "$HOME/.local/bin/bat" ] && command -v batcat >/dev/null 2>&1; then
  ln -s "$(command -v batcat)" "$HOME/.local/bin/bat"
fi

# starship: the prompt. Not in Ubuntu's repos, so use the official installer
# (idempotent — it just replaces the binary in ~/.local/bin).
if ! command -v starship >/dev/null 2>&1; then
  log "Installing starship"
  curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin"
else
  log "starship already installed ($(starship --version 2>/dev/null | head -n1))"
fi

# Make zsh the login shell so ~/.zshrc is actually used.
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
  log "Setting zsh as the login shell for $USER"
  $SUDO chsh -s "$(command -v zsh)" "$USER"
else
  log "zsh is already the login shell"
fi

# ---------------------------------------------------------------------------
log "Installing Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  log "Tailscale already installed"
fi
$SUDO systemctl enable --now tailscaled

# Bring the tailnet up unattended if an auth key was supplied:
#   TAILSCALE_AUTHKEY=tskey-auth-... ./provision/server-bootstrap.sh
# Generate one at https://login.tailscale.com/admin/settings/keys (the key
# itself still has to come from the web UI — that part can't be scripted).
# Without a key this is a no-op and `sudo tailscale up` stays a manual step.
if tailscale status >/dev/null 2>&1; then
  log "Tailscale already up ($(tailscale ip -4 2>/dev/null | head -n1))"
elif [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  log "Bringing Tailscale up with the supplied auth key"
  $SUDO tailscale up --authkey="${TAILSCALE_AUTHKEY}" --hostname="$(hostname)"
else
  log "Tailscale is installed but not logged in. Either re-run with"
  log "  TAILSCALE_AUTHKEY=tskey-auth-... $0"
  log "or run 'sudo tailscale up' manually, then re-run this script."
fi

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
  git -C "$TPM_DIR" pull -q --ff-only || log "tpm pull skipped (local changes?)"
fi

# ---------------------------------------------------------------------------
# Claude Code CLI. Installing is automated; the first-run login is an
# interactive browser/OAuth flow and stays manual (see docs/server-setup.md).
log "Installing Claude Code CLI"
if command -v claude >/dev/null 2>&1; then
  log "Claude Code already installed ($(claude --version 2>/dev/null || echo 'version unknown'))"
else
  if curl -fsSL https://claude.ai/install.sh | bash; then
    log "Claude Code installed"
  else
    log "WARNING: automatic Claude Code install failed. Install it manually,"
    log "         then re-run this script (claude-tmux.service needs it on PATH)."
  fi
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
    # Pinned: an unpinned :latest would silently pick up breaking upstream
    # changes on the next `compose up`.
    image: qmcgaw/gluetun:v3.40.0
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
    healthcheck:
      test: ["CMD", "/gluetun-entrypoint", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5

  claude-env-shell:
    # Full node image, not -slim: Claude Code needs git, which the slim
    # variant does not ship.
    image: node:20-bookworm
    container_name: claude-env-shell
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
    environment:
      # Global npm installs go to a named volume so Claude Code survives
      # container recreation (image bump, compose edit) instead of vanishing
      # into a discarded writable layer.
      - NPM_CONFIG_PREFIX=/npm-global
      - PATH=/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    volumes:
      - claude-env-workspace:/workspace
      - claude-env-config:/root/.claude
      - claude-env-npm:/npm-global
    working_dir: /workspace
    command: sleep infinity
    restart: unless-stopped

volumes:
  claude-env-workspace:
  claude-env-config:
  claude-env-npm:
EOF

if [ -f "${GLUETUN_DIR}/config/client-env.ovpn" ]; then
  (cd "$GLUETUN_DIR" && $SUDO docker compose up -d)
  if $SUDO docker ps --format '{{.Names}}' | grep -qx claude-env-shell; then
    if ! $SUDO docker exec claude-env-shell sh -c 'command -v claude' >/dev/null 2>&1; then
      log "Installing Claude Code CLI inside claude-env-shell"
      $SUDO docker exec claude-env-shell npm install -g @anthropic-ai/claude-code
    else
      log "Claude Code already installed in claude-env-shell"
    fi
  fi
else
  log "No client-env.ovpn in ${GLUETUN_DIR}/config yet — drop it there, then run:"
  log "  (cd ${GLUETUN_DIR} && docker compose up -d)"
  log "See docs/server-setup.md."
fi

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Apply dotfiles, same as the two client bootstrap scripts do. This must come
# before the tpm plugin install below, since tpm reads the plugin list out of
# the ~/.tmux.conf that chezmoi writes here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Per-machine git signing key, so signing never depends on a forwarded
# ssh-agent (which dies with the client connection). Passphrase-less by design:
# it is only ever used by git-ssh-sign on this box.
if [ ! -f "$HOME/.ssh/id_ed25519_signing" ]; then
  log "Generating a per-machine git signing key"
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519_signing" \
    -C "$(hostname) git signing" >/dev/null
  log "Register it on GitHub as a SIGNING key, then enable signing:"
  log "  gh ssh-key add ~/.ssh/id_ed25519_signing.pub --type signing --title \"\$(hostname) git signing\""
  log "  git config --file ~/.gitconfig.local commit.gpgsign true"
else
  log "git signing key already present"
fi

# shellcheck source=lib/chezmoi-apply.sh
source "${SCRIPT_DIR}/lib/chezmoi-apply.sh"
apply_dotfiles server "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Install the tmux plugins non-interactively. tpm's documented flow is to
# press `prefix + I` inside a running session; install_plugins does the same
# thing from a script, so this doesn't have to be a manual step.
log "Installing tmux plugins (tmux-resurrect, tmux-continuum)"
if [ -x "${TPM_DIR}/bin/install_plugins" ]; then
  # tpm needs a tmux server to talk to. Use a throwaway detached session so
  # this works even on a fresh boot with nothing else running, and so it
  # never touches the claude-main session.
  tmux new-session -d -s tpm-install 2>/dev/null || true
  # An ALREADY-RUNNING server (e.g. claude-main started by systemd at boot,
  # before chezmoi had written ~/.tmux.conf) never sourced the config, so tpm
  # would abort with "Tmux Plugin Manager not configured in tmux.conf".
  # Load it into the live server first. This is also what makes the new
  # settings take effect in claude-main without restarting it.
  tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true
  "${TPM_DIR}/bin/install_plugins" >/dev/null 2>&1 \
    && log "tmux plugins installed" \
    || log "WARNING: tpm install_plugins failed — run 'prefix + I' inside tmux to finish."
  tmux kill-session -t tpm-install 2>/dev/null || true
else
  log "WARNING: ${TPM_DIR}/bin/install_plugins not found — run 'prefix + I' inside tmux."
fi

# ---------------------------------------------------------------------------
log "Writing claude-tmux systemd service"
UNIT_PATH="/etc/systemd/system/claude-tmux.service"
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  log "WARNING: 'claude' is not on PATH. Install and authenticate the Claude Code CLI (see docs/server-setup.md), then re-run this script."
fi

cat <<EOF | $SUDO tee "$UNIT_PATH" >/dev/null
# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
[Unit]
Description=Persistent tmux session (claude-main) running Claude Code
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=forking
User=${USER}
Environment=HOME=${HOME}
# systemd's default PATH excludes ~/.local/bin and npm's global bin dir, so
# without this the unit fails with "claude: command not found".
Environment=PATH=${HOME}/.local/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RemainAfterExit=yes
# -A is attach-or-create: tmux-continuum's restore may have already created
# claude-main by the time this runs, and plain \`new-session\` would fail with
# "duplicate session".
ExecStart=/usr/bin/tmux new-session -A -d -s claude-main claude
ExecStop=/usr/bin/tmux kill-session -t claude-main
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable claude-tmux.service
if ! $SUDO systemctl is-active --quiet claude-tmux.service; then
  $SUDO systemctl start claude-tmux.service || \
    log "WARNING: claude-tmux.service failed to start — check 'journalctl -u claude-tmux'."
else
  log "claude-tmux.service already running"
fi

# ---------------------------------------------------------------------------
# sshd bind restriction: Tailscale interface + LAN interface only, never
# WAN. This is what lets both the Tailscale path (personal Air) and the
# OpenVPN-to-LAN path (work laptop) reach the box, while it has zero SSH
# surface on the public internet.
#
# Ubuntu 22.10+ (including 24.04) ships OpenSSH with SOCKET ACTIVATION
# enabled, where sshd_config's ListenAddress is IGNORED entirely — binding
# is controlled by ListenStream= in ssh.socket. Writing only an sshd_config
# drop-in on such a system silently leaves sshd listening on all interfaces,
# including WAN. So: detect which mechanism is live and configure that one.
#
# Both paths set FreeBind/ip_nonlocal_bind so ssh can bind the Tailscale IP
# even when it starts before tailscaled has finished assigning it —
# otherwise a reboot race makes ssh fail to start and locks you out of the
# LAN path too (Comet Pro KVM would be the only way back in).
# ---------------------------------------------------------------------------
log "Restricting sshd bind addresses"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"

# Bind EVERY LAN address, not just the one on the default route. This box has
# more than one LAN interface (e.g. ethernet on one VLAN, wifi on another),
# and the work laptop's OpenVPN-to-LAN path may arrive on either depending on
# how the UDM SE routes between the VPN pool and each VLAN. Binding them all
# means the listener is never the reason a path fails — only routing is.
#
# Selection rule: global-scope IPv4 addresses on physical interfaces that are
# RFC1918 (10/8, 172.16/12, 192.168/16). Loopback, docker/bridge/virtual
# interfaces and tailscale0 are excluded here (tailscale0 is added separately
# below). The RFC1918 filter is what enforces "never WAN" — a public address
# on this box would not match and so would never be bound.
mapfile -t LAN_IPS < <(
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '{split($4,a,"/"); print $2" "a[1]}' \
    | grep -vE '^(lo|docker|br-|veth|virbr|tailscale|tun|wg)' \
    | awk '{print $2}' \
    | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    | sort -u
)

if [ -z "$TS_IP" ]; then
  log "WARNING: Tailscale has no IP yet. Run 'sudo tailscale up', then re-run this script to lock down sshd. Leaving sshd as-is for now."
elif [ "${#LAN_IPS[@]}" -eq 0 ]; then
  log "WARNING: found no RFC1918 LAN address to bind. Leaving sshd as-is for now."
else
  log "LAN addresses to bind: ${LAN_IPS[*]}"
  log "NOTE: these must be DHCP reservations / static. If one changes, ssh keeps"
  log "      starting (FreeBind) but silently stops accepting on it — re-run this script."
  if $SUDO systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    # ---- Socket-activated (Ubuntu 22.10+, incl. 24.04) ----
    log "Detected socket-activated ssh — configuring ssh.socket (sshd_config ListenAddress would be ignored here)"
    SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
    $SUDO mkdir -p "$SOCKET_DROPIN_DIR"
    LISTEN_LINES=""
    for ip in "${LAN_IPS[@]}"; do
      LISTEN_LINES="${LISTEN_LINES}ListenStream=${ip}:22
"
    done
    NEW_CONF="# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
# Binds ssh to the Tailscale and LAN addresses only; never WAN.
[Socket]
# Empty value resets systemd's default ListenStream (0.0.0.0:22) before
# adding ours — without this, the defaults are kept and WAN stays exposed.
ListenStream=
${LISTEN_LINES}ListenStream=${TS_IP}:22
# Allow binding the Tailscale address before tailscaled has assigned it,
# so a boot-order race can't leave ssh dead.
FreeBind=true
"
    if [ "$($SUDO cat "${SOCKET_DROPIN_DIR}/10-listen-addresses.conf" 2>/dev/null)" != "$NEW_CONF" ]; then
      printf '%s' "$NEW_CONF" | $SUDO tee "${SOCKET_DROPIN_DIR}/10-listen-addresses.conf" >/dev/null
      $SUDO systemctl daemon-reload
      $SUDO systemctl restart ssh.socket
      log "ssh.socket now bound to ${LAN_IPS[*]} (LAN) and ${TS_IP} (Tailscale) on :22 only"
    else
      log "ssh.socket bind restriction already up to date"
    fi
    log "Verify with: sudo ss -tlnp | grep :22"
  else
    # ---- Traditional ssh.service ----
    log "Detected traditional ssh.service — configuring sshd_config ListenAddress"
    SSHD_DROPIN="/etc/ssh/sshd_config.d/10-listen-addresses.conf"
    LISTEN_LINES=""
    for ip in "${LAN_IPS[@]}"; do
      LISTEN_LINES="${LISTEN_LINES}ListenAddress ${ip}
"
    done
    NEW_CONF="# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
# Binds sshd to the Tailscale and LAN interfaces only; never WAN.
${LISTEN_LINES}ListenAddress ${TS_IP}
"
    if [ "$($SUDO cat "$SSHD_DROPIN" 2>/dev/null)" != "$NEW_CONF" ]; then
      printf '%s' "$NEW_CONF" | $SUDO tee "$SSHD_DROPIN" >/dev/null
      $SUDO sshd -t
      $SUDO systemctl reload ssh
      log "sshd now bound to ${LAN_IPS[*]} (LAN) and ${TS_IP} (Tailscale) only"
    else
      log "sshd bind restriction already up to date"
    fi

    # Order ssh after tailscaled and permit non-local bind, so binding the
    # Tailscale IP can't fail at boot.
    SVC_DROPIN_DIR="/etc/systemd/system/ssh.service.d"
    $SUDO mkdir -p "$SVC_DROPIN_DIR"
    SVC_CONF="# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=on-failure
RestartSec=5
"
    if [ "$($SUDO cat "${SVC_DROPIN_DIR}/10-after-tailscale.conf" 2>/dev/null)" != "$SVC_CONF" ]; then
      printf '%s' "$SVC_CONF" | $SUDO tee "${SVC_DROPIN_DIR}/10-after-tailscale.conf" >/dev/null
      $SUDO systemctl daemon-reload
    fi
    echo 'net.ipv4.ip_nonlocal_bind=1' | $SUDO tee /etc/sysctl.d/99-ssh-nonlocal-bind.conf >/dev/null
    $SUDO sysctl -q -w net.ipv4.ip_nonlocal_bind=1
    log "Verify with: sudo ss -tlnp | grep :22"
  fi
fi

log "Server bootstrap complete. See docs/server-setup.md for remaining manual steps."
