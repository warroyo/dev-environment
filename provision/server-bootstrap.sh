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
# kubectl. Not from Ubuntu's repos (they don't carry it), and not from the
# pkgs.k8s.io apt repo either: that repo's URL pins a Kubernetes minor
# version, so every bump means editing both this script and the sources.list
# already on the box. The upstream release channel bakes no version in here.
#
# Like starship and chezmoi this goes in ~/.local/bin, so it needs no sudo and
# is already on PATH for both interactive shells and claude-tmux.service.
#
# Only installed when missing — re-running this script does NOT upgrade an
# existing kubectl. To move to current stable, delete the binary and re-run.
if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl"
  # dpkg's names (amd64/arm64) are the same ones the release channel uses.
  KUBECTL_ARCH="$(dpkg --print-architecture)"
  KUBECTL_TMP="$(mktemp -d)"
  # Checksum-verified: this is a raw binary over plain HTTPS with no package
  # manager doing signature checking for us.
  if KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
    && curl -fsSL -o "${KUBECTL_TMP}/kubectl" \
         "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl" \
    && curl -fsSL -o "${KUBECTL_TMP}/kubectl.sha256" \
         "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl.sha256" \
    && (cd "$KUBECTL_TMP" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check --status)
  then
    install -m 755 "${KUBECTL_TMP}/kubectl" "$HOME/.local/bin/kubectl"
    log "kubectl ${KUBECTL_VERSION} installed"
  else
    # Not fatal: nothing else in this script depends on kubectl.
    log "WARNING: kubectl install failed — re-run this script to retry."
  fi
  rm -rf "$KUBECTL_TMP"
else
  log "kubectl already installed ($(kubectl version --client 2>/dev/null | head -n1))"
fi

# ---------------------------------------------------------------------------
# krew — kubectl's plugin manager. Same shape as the kubectl block above: a raw
# binary from a GitHub release over plain HTTPS with no package manager
# checking signatures, so verify the published sha256 before running it.
#
# krew installs ITSELF: the downloaded binary's `install krew` subcommand is the
# documented bootstrap, and it puts everything under ~/.krew (no sudo). Plugins
# then land in ~/.krew/bin, which 40_path.sh adds to PATH — kubectl finds
# plugins by scanning PATH, so without that entry even `kubectl krew` is an
# unknown command.
#
# Only installed when missing. To upgrade later: `kubectl krew upgrade krew`.
if [ ! -x "$HOME/.krew/bin/kubectl-krew" ]; then
  log "Installing krew"
  # krew's asset names use Go's arch spelling, which matches dpkg's for both
  # architectures this box could be (amd64/arm64).
  KREW_ARCH="$(dpkg --print-architecture)"
  KREW_TARBALL="krew-linux_${KREW_ARCH}"
  KREW_TMP="$(mktemp -d)"
  # latest/download resolves to the newest release, so no version is pinned
  # here — same reasoning as kubectl's stable.txt channel.
  KREW_URL="https://github.com/kubernetes-sigs/krew/releases/latest/download"
  if curl -fsSL -o "${KREW_TMP}/${KREW_TARBALL}.tar.gz" "${KREW_URL}/${KREW_TARBALL}.tar.gz" \
    && curl -fsSL -o "${KREW_TMP}/${KREW_TARBALL}.tar.gz.sha256" \
         "${KREW_URL}/${KREW_TARBALL}.tar.gz.sha256" \
    && (
         cd "$KREW_TMP" \
         && echo "$(awk '{print $1}' "${KREW_TARBALL}.tar.gz.sha256")  ${KREW_TARBALL}.tar.gz" \
            | sha256sum --check --status
       ) \
    && tar -xzf "${KREW_TMP}/${KREW_TARBALL}.tar.gz" -C "$KREW_TMP" \
    && "${KREW_TMP}/${KREW_TARBALL}" install krew
  then
    log "krew installed to ~/.krew"
  else
    # Not fatal: nothing else in this script depends on krew.
    log "WARNING: krew install failed — re-run this script to retry."
  fi
  rm -rf "$KREW_TMP"
else
  log "krew already installed"
fi

# ---------------------------------------------------------------------------
# kubectx / kubens — switch clusters and namespaces without editing kubeconfig.
#
# NOT the Ubuntu `kubectx` package: that one is universe-only and lags the
# upstream releases badly. NOT the krew `ctx`/`ns` plugins either — those are
# the same author's code, but they're only reachable as `kubectl ctx`, and the
# point of these is the short standalone names.
#
# The release assets carry the version in their filename, so unlike krew there
# is no fixed latest/download URL — resolve the tag from the redirect that
# /releases/latest issues, then build the asset names from it.
if ! command -v kubectx >/dev/null 2>&1; then
  log "Installing kubectx / kubens"
  # This project's assets use uname's arch spelling (x86_64), not dpkg's.
  case "$(dpkg --print-architecture)" in
    amd64) KCTX_ARCH="x86_64" ;;
    arm64) KCTX_ARCH="arm64" ;;
    *)     KCTX_ARCH="" ;;
  esac
  KCTX_TMP="$(mktemp -d)"
  KCTX_VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/ahmetb/kubectx/releases/latest 2>/dev/null | sed 's#.*/tag/##')"
  if [ -z "$KCTX_ARCH" ]; then
    log "WARNING: unsupported architecture for kubectx — skipping."
  elif [ -z "$KCTX_VERSION" ]; then
    log "WARNING: could not resolve the latest kubectx release — re-run to retry."
  else
    KCTX_URL="https://github.com/ahmetb/kubectx/releases/download/${KCTX_VERSION}"
    # One checksums.txt covers every asset in the release, so fetch it once and
    # let sha256sum --ignore-missing check just the two files we downloaded.
    if curl -fsSL -o "${KCTX_TMP}/kubectx.tar.gz" \
         "${KCTX_URL}/kubectx_${KCTX_VERSION}_linux_${KCTX_ARCH}.tar.gz" \
      && curl -fsSL -o "${KCTX_TMP}/kubens.tar.gz" \
           "${KCTX_URL}/kubens_${KCTX_VERSION}_linux_${KCTX_ARCH}.tar.gz" \
      && curl -fsSL -o "${KCTX_TMP}/checksums.txt" "${KCTX_URL}/checksums.txt" \
      && (
           cd "$KCTX_TMP" \
           && mv kubectx.tar.gz "kubectx_${KCTX_VERSION}_linux_${KCTX_ARCH}.tar.gz" \
           && mv kubens.tar.gz  "kubens_${KCTX_VERSION}_linux_${KCTX_ARCH}.tar.gz" \
           && sha256sum --check --status --ignore-missing checksums.txt \
           && tar -xzf "kubectx_${KCTX_VERSION}_linux_${KCTX_ARCH}.tar.gz" \
           && tar -xzf "kubens_${KCTX_VERSION}_linux_${KCTX_ARCH}.tar.gz"
         )
    then
      install -m 755 "${KCTX_TMP}/kubectx" "$HOME/.local/bin/kubectx"
      install -m 755 "${KCTX_TMP}/kubens"  "$HOME/.local/bin/kubens"
      log "kubectx / kubens ${KCTX_VERSION} installed"
    else
      # Not fatal: nothing else in this script depends on them.
      log "WARNING: kubectx install failed — re-run this script to retry."
    fi
  fi
  rm -rf "$KCTX_TMP"
else
  log "kubectx already installed ($(kubectx --version 2>/dev/null || echo 'version unknown'))"
fi

# ---------------------------------------------------------------------------
# Node.js — provides npm and npx. Needed for npx-based CLIs (e.g. `npx skills
# add <repo>`, for installing Claude Code skills from a GitHub repo). Via
# NodeSource's apt repo rather than nvm: this is a single always-on system,
# not a per-project version matrix, so one system-wide LTS is enough and apt
# keeps it patched like everything else installed this way (Docker, Tailscale).
log "Installing Node.js"
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
else
  log "Node.js already installed ($(node --version))"
fi

# npm's default global prefix is root-owned, so `npm install -g` (and some of
# npx's own caching) would need sudo. Point it at a per-user prefix instead —
# this is also why claude-tmux.service's PATH already lists ~/.npm-global/bin
# (see the systemd unit further down): that entry has had nothing to point at
# until now.
if command -v npm >/dev/null 2>&1; then
  if [ "$(npm config get prefix 2>/dev/null)" != "$HOME/.npm-global" ]; then
    log "Setting npm's global prefix to ~/.npm-global"
    npm config set prefix "$HOME/.npm-global"
  else
    log "npm global prefix already set to ~/.npm-global"
  fi
  mkdir -p "$HOME/.npm-global/bin"
fi

# ---------------------------------------------------------------------------
# Terraform — via HashiCorp's apt repo, same pattern as eza's: add the repo
# once, then let apt track and patch it like everything else installed this
# way (Docker, Tailscale, Node.js).
log "Installing Terraform"
if ! command -v terraform >/dev/null 2>&1; then
  $SUDO mkdir -p /etc/apt/keyrings
  wget -qO- https://apt.releases.hashicorp.com/gpg \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | $SUDO tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y terraform
else
  log "Terraform already installed ($(terraform version | head -n1))"
fi

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
# Second (unrelated) OpenVPN environment — runs directly on the host under
# systemd.
#
# This used to live inside a gluetun container, on the theory that the OpenVPN
# client had to be kept out of the host routing table so it could never contend
# with Tailscale for the default route. That does not apply to this particular
# client-env.ovpn:
#
#   - it sets no redirect-gateway, so it never touches the default route;
#   - Tailscale is a /32 on tailscale0 resolved through its own routing table
#     (ip rule 5270 -> table 52), and 100.64/10 overlaps none of the pushed
#     subnets;
#   - the LAN's 10.10.2.0/24 is more specific than the pushed 10.0.0.0/10, so
#     the LAN and the default gateway keep winning.
#
# The one real collision was the pushed 172.17.0.0/24 against Docker's default
# bridge (172.17.0.0/16 on docker0): /24 beats /16, so the tunnel would have
# captured exactly the range docker0 hands out. The daemon.json below moves
# docker0 out of the way.
#
# Running on the host rather than in a namespace reached by `docker exec` also
# means Claude Code here gets the real home directory, ssh keys, gitconfig and
# editor instead of a bare node image with none of them.
#
# Deliberately NOT enabled at boot: this environment's identity is a
# certificate shared with other machines and the server accepts only one live
# connection per identity, so auto-connecting would silently take the session
# from whoever else is using it. Connect with `client-vpn up`, disconnect with
# `client-vpn down`.
# ---------------------------------------------------------------------------
log "Setting up the second (unrelated) OpenVPN environment on the host"

# openvpn-systemd-resolved ships update-systemd-resolved, which is what applies
# the tunnel's pushed DNS. Without it the tunnel comes up fine and internal
# names still do not resolve — see the drop-in further down.
$SUDO apt-get install -y --no-install-recommends openvpn openvpn-systemd-resolved

OVPN_CONF="/etc/openvpn/client/client-env.conf"
LEGACY_GLUETUN_DIR="/opt/claude-env-vpn"

# Retire the old gluetun stack before starting the host tunnel: both use the
# same shared certificate, and two live connections is the exact problem this
# environment already suffers from.
if [ -f "${LEGACY_GLUETUN_DIR}/docker-compose.yml" ]; then
  log "Retiring the old gluetun stack"
  # Volumes are left in place on purpose: `down -v` would discard them, and
  # they are not this script's to throw away.
  (cd "$LEGACY_GLUETUN_DIR" && $SUDO docker compose down --remove-orphans) || true
  $SUDO mv "${LEGACY_GLUETUN_DIR}/docker-compose.yml" \
           "${LEGACY_GLUETUN_DIR}/docker-compose.yml.retired"
fi

# Move docker0 off 172.17.0.0/16 so the 172.17.0.0/24 the tunnel pushes cannot
# capture it: /24 beats /16, so the tunnel would otherwise take exactly the
# addresses the bridge hands out. 172.18/19 are picked because nothing the
# tunnel pushes overlaps them, and neither does either local network. Check
# `ip route` against the live tunnel before changing these.
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_DAEMON_JSON" ]; then
  log "Moving docker0 off the subnet the client VPN pushes"
  $SUDO mkdir -p /etc/docker
  $SUDO tee "$DOCKER_DAEMON_JSON" >/dev/null <<'JSON'
{
  "bip": "172.19.255.1/24",
  "default-address-pools": [
    { "base": "172.18.0.0/16", "size": 24 },
    { "base": "172.19.0.0/17", "size": 24 }
  ]
}
JSON
  $SUDO systemctl restart docker
elif ! grep -q '"bip"' "$DOCKER_DAEMON_JSON" 2>/dev/null; then
  # Not ours to rewrite — merging blind could silently drop settings.
  log "WARNING: ${DOCKER_DAEMON_JSON} exists but sets no \"bip\"."
  log "  docker0 is likely still on 172.17.0.0/16, which the client VPN's"
  log "  pushed 172.17.0.0/24 will capture, breaking host<->container traffic"
  log "  on the default bridge. Add a bip outside that range by hand."
fi

if [ ! -f "$OVPN_CONF" ] && [ -f "${LEGACY_GLUETUN_DIR}/config/client-env.ovpn" ]; then
  log "Migrating client-env.ovpn out of ${LEGACY_GLUETUN_DIR}/config"
  $SUDO install -m 600 -o root -g root \
    "${LEGACY_GLUETUN_DIR}/config/client-env.ovpn" "$OVPN_CONF"
fi

if [ -f "$OVPN_CONF" ]; then
  # The file embeds <key>, so it must not be world-readable.
  $SUDO chown root:root "$OVPN_CONF"
  $SUDO chmod 600 "$OVPN_CONF"
  log "OpenVPN client config in place at ${OVPN_CONF}"
  log "  Connect with 'client-vpn up' — not enabled at boot, shared identity."
else
  log "WARNING: no OpenVPN config at ${OVPN_CONF}."
  log "  Copy that environment's .ovpn there, then re-run this script."
  log "  See docs/server-setup.md."
fi

# Hand the tunnel's pushed DNS to systemd-resolved.
#
# The server pushes a resolver and a search domain (dhcp-option DNS and
# DOMAIN-SEARCH), but OpenVPN on Linux only logs those — it has no built-in way
# to apply them. The symptom is a tunnel that looks completely healthy while
# every internal name fails: `resolvectl status tun0` reports "Current Scopes:
# none", while a direct `dig @<pushed-resolver> <name>` answers correctly the
# whole time. `journalctl -u openvpn-client@client-env | grep PUSH_REPLY` shows
# what the server actually sent.
#
# This is a drop-in rather than extra directives appended to the .conf so that
# the dropped-in .ovpn stays byte-for-byte what that environment handed us —
# re-running this script can't accumulate edits in it, and replacing it can't
# silently drop them.
#
# systemd-resolved treats a search domain as a routing domain too, so the
# pushed DOMAIN-SEARCH is what keeps this split: only that environment's own
# domain resolves through the tunnel, and the rest of the box's DNS is
# untouched while connected.
OVPN_DROPIN_DIR="/etc/systemd/system/openvpn-client@client-env.service.d"
# Probed rather than hardcoded: Debian/Ubuntu's openvpn-systemd-resolved puts
# this straight in /etc/openvpn, while other packagings use a scripts/ subdir or
# libexec. Guessing wrong here is silent — the drop-in never gets written and
# the tunnel comes up with no DNS.
UPDATE_RESOLVED=""
for _candidate in \
  /etc/openvpn/update-systemd-resolved \
  /etc/openvpn/scripts/update-systemd-resolved \
  /usr/libexec/openvpn/update-systemd-resolved
do
  if [ -x "$_candidate" ]; then
    UPDATE_RESOLVED="$_candidate"
    break
  fi
done
unset _candidate

if [ -n "$UPDATE_RESOLVED" ]; then
  log "Wiring the tunnel's pushed DNS into systemd-resolved"
  $SUDO mkdir -p "$OVPN_DROPIN_DIR"
  # ExecStart is cleared first because systemd otherwise *appends* to it. The
  # base command is copied from the packaged openvpn-client@.service; keep it in
  # step if that unit ever changes.
  $SUDO tee "${OVPN_DROPIN_DIR}/dns.conf" >/dev/null <<EOF
# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
[Service]
ExecStart=
ExecStart=/usr/sbin/openvpn --suppress-timestamps --nobind --config %i.conf \\
  --script-security 2 \\
  --up ${UPDATE_RESOLVED} \\
  --up-restart \\
  --down ${UPDATE_RESOLVED} \\
  --down-pre
EOF
  $SUDO systemctl daemon-reload
else
  log "WARNING: no update-systemd-resolved found, so the tunnel's pushed DNS"
  log "  will not be applied and internal names will not resolve while"
  log "  connected. Install openvpn-systemd-resolved and re-run this script."
fi

# ---------------------------------------------------------------------------
# Route the lab subnet for LAN and Teleport clients.
#
# The work laptop used to reach that environment through `browser-vpn` — an
# `ssh -D` SOCKS5 proxy to this box, since deleted. Over office wifi that path
# was SOCKS over SSH over the gateway's WireGuard tunnel: TCP inside TCP, where
# every handshake and every DNS lookup paid a full round trip. This makes the
# box a router for the one subnet that is actually needed instead, so the
# laptop gets a real network path and no proxy at all.
#
# Only 10.47.0.0/16 and the lab resolver are forwarded, deliberately. The
# tunnel also pushes 10.0.0.0/10, which contains this LAN, and 172.17.0.0/24,
# which is Docker's usual bridge — see docs/ARCHITECTURE.md. Neither is
# something to hand a laptop that has to keep working on someone else's
# network.
#
# Nothing needs adding to this box's routing table: both prefixes already sit
# inside routes the tunnel installs itself. What is missing is forwarding and
# NAT — the lab has no route back to this LAN, let alone to the gateway's
# Teleport pool, so replies would otherwise never come home.
#
# This deliberately does NOT go through ufw. ufw is installed here but
# DISABLED (ENABLED=no in /etc/ufw/ufw.conf), which is easy to misread: the
# ufw systemd unit still reports "active" because it is a oneshot that reads
# that flag and exits. While disabled, ufw applies nothing — not before.rules,
# not `ufw route` rules — so anything written through it is inert. Enabling it
# to fix that would turn on INPUT DROP on a box only reachable over
# SSH/Tailscale/mosh, which is a much larger decision than routing one subnet.
# So the rules are installed directly instead, by a unit that owns them.
# ---------------------------------------------------------------------------
LAB_SUBNET="10.47.0.0/16"
LAB_DNS="172.21.0.90"
LAB_RULES_BIN="/usr/local/sbin/lab-routing-rules"
LAB_UNIT="lab-routing.service"

log "Routing ${LAB_SUBNET} and the lab resolver (${LAB_DNS}) to LAN clients"

# IP forwarding is on at runtime already, but only because dockerd sets it when
# it starts — nothing configures it. That is a side effect, not a setting, and
# it disappears the moment Docker does.
echo 'net.ipv4.ip_forward=1' | $SUDO tee /etc/sysctl.d/99-lab-routing.conf >/dev/null
$SUDO sysctl -q -w net.ipv4.ip_forward=1

# The rules live in a script rather than inline ExecStart= lines so they can be
# re-applied by hand after anything that rebuilds the filter table (a Docker
# restart, or enabling ufw later) with a single `systemctl restart`.
#
# Every rule is added through an `-C || -A` guard, so this is safe to run any
# number of times and will not stack duplicates. That also means it stays
# correct if ufw is ever enabled and installs an identical MASQUERADE from
# before.rules: -C matches it and the add is skipped.
$SUDO tee "$LAB_RULES_BIN" >/dev/null <<'LABRULES'
#!/bin/sh
# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
#
# Forwards the lab subnet and the lab resolver between the LAN and the
# client-env OpenVPN tunnel, and NATs them so the lab can answer.
set -eu

LAB_SUBNET="10.47.0.0/16"
LAB_DNS="172.21.0.90"

CHAIN="LAB-ROUTING"

# The forward rules live in a chain of their own, flushed and rebuilt on every
# run. Rules appended straight to FORWARD cannot be cleaned up safely — a rule
# whose shape changed between versions no longer matches `-C`, so it is neither
# recognised nor removed and just accumulates. Owning a chain makes that
# impossible: whatever was here before is gone before anything is added.
iptables -N "$CHAIN" 2>/dev/null || true
iptables -F "$CHAIN"
iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN"

# Retire rules left in FORWARD by earlier versions of this script, which pinned
# the LAN side to the default-route interface. Looping because -D removes one
# match at a time.
for _if in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|tun0)$'); do
  for _dest in "$LAB_SUBNET" "$LAB_DNS"; do
    while iptables -D FORWARD -i "$_if" -o tun0 -d "$_dest" -j ACCEPT 2>/dev/null
      do :; done
  done
  while iptables -D FORWARD -i tun0 -o "$_if" -m conntrack \
      --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    do :; done
done

# No source match on purpose: the source is whatever the gateway hands a
# Teleport client (or whatever a travel router NATs its LAN behind), and that
# is not knowable from here. Matching only `-o tun0` covers every client
# without guessing. Inert while the tunnel is down, and a no-op for this box's
# own traffic, which already leaves with tun0's address.
iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# Scoped by DESTINATION, not by inbound interface. An earlier version pinned
# these to the default-route interface on the theory that lab clients always
# arrive from the UDM SE. They do not: this box has LAN legs on two VLANs, and
# a client on the other one had its requests forwarded out fine while every
# reply was dropped on the way back — the return rule named the wrong -o. The
# destination match is the constraint that actually matters, and it holds no
# matter which leg a client arrives on.
for _dest in "$LAB_SUBNET" "$LAB_DNS"; do
  iptables -A "$CHAIN" -o tun0 -d "$_dest" -j ACCEPT
done

# Docker sets the FORWARD policy to DROP, so the return direction needs saying
# out loud even though conntrack knows the flow.
iptables -A "$CHAIN" -i tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Clamp the TCP MSS on anything entering the tunnel.
#
# tun0's MTU is 1500 — the same as the physical link — so a full-size segment
# plus OpenVPN's encapsulation exceeds the real path MTU. The server's own
# traffic survives on OpenVPN's mssfix, but forwarded traffic should not depend
# on a setting in a config file this script does not own. Without clamping the
# failure is nasty to diagnose: ping works, DNS works, small requests work, and
# large transfers or HTTPS pages hang forever.
#
# --set-mss, NOT --clamp-mss-to-pmtu: clamping derives the value from the
# outgoing route's MTU, which here is tun0's 1500, giving MSS 1460 — precisely
# the value that blackholes. 1350 leaves comfortable room for OpenVPN's header,
# packet id and AEAD tag on top of the outer IP/UDP headers.
#
# mangle, not filter: the TCPMSS target is only valid in the mangle table, so
# this one rule cannot live in the chain above. It is guarded rather than
# flushed, like the MASQUERADE.
iptables -t mangle -C FORWARD -o tun0 -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --set-mss 1350 2>/dev/null \
  || iptables -t mangle -A FORWARD -o tun0 -p tcp --tcp-flags SYN,RST SYN \
       -j TCPMSS --set-mss 1350
LABRULES
$SUDO chmod 755 "$LAB_RULES_BIN"

# After docker.service because Docker rebuilds its chains and re-inserts its
# jumps at the top of FORWARD on start; running after it keeps the ordering
# predictable on boot.
$SUDO tee "/etc/systemd/system/${LAB_UNIT}" >/dev/null <<EOF
# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
[Unit]
Description=Forward the lab subnet to the client-env OpenVPN tunnel
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${LAB_RULES_BIN}

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable "$LAB_UNIT" >/dev/null 2>&1 || true
# restart, not `enable --now`: the unit is Type=oneshot with RemainAfterExit,
# so it reads as "active" forever after its first run and `--now` would decline
# to start it again. Rewriting the rules script would then have no effect until
# the next reboot — which is exactly how a fixed rule set sat on disk unused.
# Re-running is cheap and safe: the script flushes its own chain first.
$SUDO systemctl restart "$LAB_UNIT" >/dev/null 2>&1 || true
if $SUDO systemctl is-active --quiet "$LAB_UNIT"; then
  log "  ${LAB_UNIT} active — forwarding and NAT in place"
else
  log "  WARNING: ${LAB_UNIT} did not start. Check:"
  log "    journalctl -u ${LAB_UNIT} -n 20"
fi

log "  Gateway side is manual: a static route for ${LAB_SUBNET} pointing at"
log "  this box. See docs/client-work-setup.md."

# ---------------------------------------------------------------------------
# Split DNS for the lab zone, served on a port nothing intercepts.
#
# Clients used to point /etc/resolver/set.lab straight at the lab's own
# resolver and let this box route the packets. That works only while every
# device between the laptop and here leaves port 53 alone, and plenty do not:
# a UniFi gateway, a hotel AP or a captive-portal router will happily DNAT
# "anything to port 53" to itself no matter which address was addressed.
#
# The failure is a nasty one to read, because nothing times out. The
# interceptor answers — faster than the real resolver could, since it is
# nearer — with NXDOMAIN and a root-server SOA. Routing looks perfect and
# traceroute rides the route to the far end, because traceroute never sends
# anything on port 53. Only DNS is stolen, so the one address used solely for
# DNS looks unreachable while every other address on the same route works.
#
# So this stops putting port 53 on the wire at all. dnsmasq listens here on
# 5300, forwards only *.set.lab into the tunnel, and clients ask it instead of
# asking the lab directly. 5300 rather than 5353, which belongs to mDNS.
#
# It also retires the 172.21.0.90/32 static route the gateway needed: the lab
# resolver is now reached only by this box, which already has it via tun0.
# ---------------------------------------------------------------------------
LAB_DNS_PORT="5300"
LAB_ZONE="set.lab"
DNSMASQ_CONF="/etc/dnsmasq.d/lab-split-dns.conf"

log "Serving split DNS for *.${LAB_ZONE} on port ${LAB_DNS_PORT}"

# Bind every LAN address, for the reason the sshd section below binds them
# all: this box has legs on two VLANs and a client may arrive on either.
mapfile -t DNS_LISTEN_IPS < <(
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '{split($4,a,"/"); print $2" "a[1]}' \
    | grep -vE '^(lo|docker|br-|veth|virbr|tailscale|tun|wg)' \
    | awk '{print $2}' \
    | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    | sort -u
)
DNS_LISTEN="127.0.0.1"
for ip in "${DNS_LISTEN_IPS[@]}"; do
  DNS_LISTEN="${DNS_LISTEN},${ip}"
done

# The config is written BEFORE the package is installed, deliberately. Ubuntu's
# dnsmasq starts on install with an empty config, which means port 53 on the
# wildcard address — and that collides with systemd-resolved's 127.0.0.53:53
# and fails. Having port=${LAB_DNS_PORT} on disk first means its very first
# start is the correct one.
$SUDO mkdir -p /etc/dnsmasq.d
$SUDO tee "$DNSMASQ_CONF" >/dev/null <<EOF
# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.

# Not 53: that port is intercepted on networks this laptop has to work from.
port=${LAB_DNS_PORT}

# bind-dynamic rather than bind-interfaces: these addresses come from DHCP
# reservations, and bind-interfaces makes a missing one a start-up failure at
# boot. bind-dynamic picks addresses up as they appear.
bind-dynamic
listen-address=${DNS_LISTEN}

# Never serve into the tunnel itself — the lab does not need a resolver from
# us, and offering one to a third-party network is not a favour.
except-interface=tun0

# no-resolv plus a single domain-scoped upstream is what keeps this from being
# an open resolver: ${LAB_ZONE} is forwarded, and there is no upstream for
# anything else, so every other query is refused rather than recursed.
no-resolv
no-hosts
server=/${LAB_ZONE}/${LAB_DNS}

cache-size=1000
EOF

$SUDO apt-get install -y --no-install-recommends dnsmasq
$SUDO systemctl enable dnsmasq >/dev/null 2>&1 || true
# restart, not start: picks up an edited config on a re-run.
$SUDO systemctl restart dnsmasq || \
  log "WARNING: dnsmasq failed to start — check 'journalctl -u dnsmasq -n 30'."

if $SUDO systemctl is-active --quiet dnsmasq; then
  log "  dnsmasq listening on ${DNS_LISTEN} port ${LAB_DNS_PORT}"
  log "  clients point /etc/resolver/${LAB_ZONE} here — see provision/lib/lab-dns.sh"
fi

# ---------------------------------------------------------------------------
# Apply dotfiles, same as the two client bootstrap scripts do. This must come
# before the tpm plugin install below, since tpm reads the plugin list out of
# the ~/.tmux.conf that chezmoi writes here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
# Written, but deliberately NOT enabled. herdr owns the persistent session
# (herdr-setup.sh, called at the end of this script); this unit stays on disk
# so `provision/herdr-setup.sh --uninstall` can hand the session back to tmux
# in one command instead of a re-provision. tmux itself stays installed for
# ad-hoc use, which is also what `claude-attach --tmux` reaches.
log "Writing claude-tmux systemd service (disabled fallback)"
UNIT_PATH="/etc/systemd/system/claude-tmux.service"
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  log "WARNING: 'claude' is not on PATH. Install and authenticate the Claude Code CLI (see docs/server-setup.md), then re-run this script."
fi

# Where the persistent session starts. Defaults to ~/workspace rather than
# $HOME: it is the natural project root, and it keeps Claude Code's read/write
# scope off dotfiles, ~/.ssh and everything else in the home directory.
#   CLAUDE_WORKDIR=~/some/project ./provision/server-bootstrap.sh
CLAUDE_WORKDIR="${CLAUDE_WORKDIR:-$HOME/workspace}"
mkdir -p "$CLAUDE_WORKDIR"
LOGIN_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
log "claude-main will start in ${CLAUDE_WORKDIR}"

# Claude Code asks "is this a project you trust?" the first time it runs in a
# directory, and requires an interactive answer. systemd starts the session
# detached with nobody to answer, so claude prints the prompt, gets no input
# and exits — leaving an empty session. Pre-record the trust decision for the
# directory we are about to point it at.
#
# This edits Claude Code's own config file, which is not a documented
# interface: if its format changes in an update this silently stops working
# and you get the interactive prompt back (the session still survives, thanks
# to the shell fallback in ExecStart — you would just have to answer once).
CLAUDE_CFG="$HOME/.claude.json"
if [ -f "$CLAUDE_CFG" ] && command -v python3 >/dev/null 2>&1; then
  if python3 - "$CLAUDE_CFG" "$CLAUDE_WORKDIR" <<'PYEOF'
import json, shutil, sys
cfg_path, workdir = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = json.load(f)
proj = cfg.setdefault("projects", {}).setdefault(workdir, {})
if proj.get("hasTrustDialogAccepted") is True:
    sys.exit(1)                      # already trusted; nothing to do
shutil.copy2(cfg_path, cfg_path + ".bak")
proj["hasTrustDialogAccepted"] = True
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
  then
    log "Recorded Claude Code trust for ${CLAUDE_WORKDIR} (backup: ${CLAUDE_CFG}.bak)"
  else
    log "Claude Code already trusts ${CLAUDE_WORKDIR}"
  fi
else
  log "NOTE: ${CLAUDE_CFG} not found — run 'claude' once in ${CLAUDE_WORKDIR} and accept the trust prompt."
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
# systemd defaults WorkingDirectory to / for services, so without this the
# session (and everything you run in it) starts at the filesystem root.
WorkingDirectory=${CLAUDE_WORKDIR}
Environment=HOME=${HOME}
# systemd's default PATH excludes ~/.local/bin and npm's global bin dir, so
# without this the unit fails with "claude: command not found". ~/.krew/bin is
# here for the same reason it is in 40_path.sh: kubectl discovers plugins by
# scanning PATH, so without it Claude Code in this session sees no krew plugins
# (and no `kubectl krew`) even though they are installed.
Environment=PATH=${HOME}/.local/bin:${HOME}/.krew/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# -A is attach-or-create: tmux-continuum's restore may have already created
# claude-main by the time this runs, and plain \`new-session\` would fail with
# "duplicate session".
#
# claude-session runs claude, then drops to a login shell with a message
# saying how to restart it. Wrapping matters: tmux ends a session when its
# last command exits, so running claude directly means quitting or crashing it
# destroys claude-main and leaves nothing to attach to.
ExecStart=/usr/bin/tmux new-session -A -d -s claude-main -c ${CLAUDE_WORKDIR} ${HOME}/.local/bin/claude-session
ExecStop=/usr/bin/tmux kill-session -t claude-main
# No RemainAfterExit: it makes systemd report "active (exited)" forever even
# after the tmux server is gone, which hides exactly the failure this unit
# exists to prevent. Note \`systemctl is-active\` still is not proof on its own
# (any lingering process in the cgroup counts) — provision/verify-server.sh
# checks \`tmux has-session\`, which is.
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
# Left disabled on purpose — see the note above. herdr-setup.sh disables it too
# if an older provision run had enabled it, so this is belt and braces for a
# fresh machine that has never had the tmux unit running.
$SUDO systemctl disable claude-tmux.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# The persistent session itself. Kept in its own script because it is also the
# thing you re-run on its own when only this part changes, and because
# --uninstall there is the documented way back to tmux.
#
# It runs after the chezmoi apply above on purpose: it needs
# ~/.local/bin/herdr-main-workspace, which is what creates the claude-main
# workspace and starts claude in it.
log "Installing herdr and the persistent session"
"${SCRIPT_DIR}/herdr-setup.sh"

# ---------------------------------------------------------------------------
log "Writing claude-telegram-bot systemd service"
# The phone entry point: a Telegram bot that runs claude-open, which starts a
# detached tmux session with `claude --remote-control` in a directory under
# ~/workspace. The conversation itself then happens in the Claude app over
# Remote Control — the bot only ever starts, lists and stops sessions.
#
# The token and the chat allow-list live in ~/.secrets/telegram-bot, outside
# git like every other credential here. The unit is written unconditionally so
# it is ready the moment that file exists, but it is only ENABLED once it does:
# without a token the service would fail and Restart=always would turn that
# into a permanent restart loop in the journal.
TG_UNIT_PATH="/etc/systemd/system/claude-telegram-bot.service"
TG_SECRETS="$HOME/.secrets/telegram-bot"

cat <<EOF | $SUDO tee "$TG_UNIT_PATH" >/dev/null
# Managed by dev-environment/provision/server-bootstrap.sh — do not edit by hand.
[Unit]
Description=Telegram bot that opens Claude Code sessions in ~/workspace
After=network-online.target claude-tmux.service
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${HOME}
Environment=HOME=${HOME}
# Same PATH as claude-tmux.service, and for the same reason: systemd's default
# omits ~/.local/bin (claude-open, claude-session) and the npm global bin dir
# (claude itself), so without this every /open fails with "command not found".
Environment=PATH=${HOME}/.local/bin:${HOME}/.krew/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${HOME}/.local/bin/claude-telegram-bot
# Long-polling against api.telegram.org: transient network failures are normal
# and the bot handles them itself, but a hard exit (bad token, killed process)
# should still come back.
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
if [ -r "$TG_SECRETS" ]; then
  $SUDO systemctl enable claude-telegram-bot.service >/dev/null 2>&1 || true
  # restart, not start: picks up an edited token or allow-list on a re-run.
  $SUDO systemctl restart claude-telegram-bot.service || \
    log "WARNING: claude-telegram-bot.service failed to start — check 'journalctl -u claude-telegram-bot'."
else
  $SUDO systemctl disable claude-telegram-bot.service >/dev/null 2>&1 || true
  log "  no ${TG_SECRETS} yet — bot left disabled. To enable it:"
  log "    TELEGRAM_BOT_TOKEN=... ./provision/telegram-bot-setup.sh"
  log "  That finds your chat id, writes the secrets file and enables the unit."
  log "  See docs/server-setup.md for the @BotFather half."
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
