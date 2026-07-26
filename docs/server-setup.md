# Server setup (`ubuntu-home`)

The sole, always-on Claude Code host. See
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md) for why session state lives here
and nowhere else.

## 1. Run the bootstrap script (first pass)

```sh
git clone <this-repo-url> ~/dev-environment
cd ~/dev-environment
./provision/server-bootstrap.sh
```

Installs zsh (and sets it as your login shell), tmux + tpm, mosh,
`ripgrep`/`fd`/`bat`/`eza`/`fzf`, Tailscale, Docker, and chezmoi, and writes
the `claude-tmux.service` systemd unit and gluetun's `docker-compose.yml`.

Two warnings are expected on this first run and are not errors:

- **sshd lockdown skipped** — Tailscale has no IP yet. Fixed by step 4.
- **`claude` not on PATH** — the CLI isn't installed yet. Fixed by step 2.

The script is idempotent; you'll run it again in step 4. Note that Docker
group membership doesn't apply to your current shell session until you log
out and back in — the script uses `sudo docker` internally to work around
that, but your own `docker` commands will need a fresh login.

## 2. Install and authenticate the Claude Code CLI

If you haven't already, install `claude` and complete its one-time
interactive login. This isn't scripted here since it requires interactive
auth — see Anthropic's Claude Code docs for the current install command.
`claude-tmux.service` (from step 1) assumes `claude` is already on `PATH`
for your user.

## 3. Manual: `tailscale up`

```sh
sudo tailscale up
```

Interactive — follow the printed auth URL. Confirm the machine shows up in
your tailnet and note its Tailscale hostname (should be `ubuntu-home`; used
throughout `dotfiles/.chezmoidata.yaml` and the SSH config template).

## 4. Run the bootstrap script again

```sh
./provision/server-bootstrap.sh
```

Now that Tailscale has an IP, this run locks ssh down to the Tailscale IP
and the LAN IP only, never WAN.

**Ubuntu 24.04 uses socket activation** (`ssh.socket`), where
`sshd_config`'s `ListenAddress` is ignored entirely — binding is controlled
by `ListenStream=` in the socket unit. The script detects which mechanism is
live and configures the right one, so the authoritative check is what's
actually listening, not what's in `sshd_config`:

```sh
sudo ss -tlnp | grep :22
```

You should see exactly two entries — the LAN IP and the Tailscale IP — and
**no** `0.0.0.0:22` or `*:22`. If you see a wildcard bind, ssh is still
exposed on every interface including WAN.

## 5. Apply dotfiles via chezmoi

```sh
chezmoi init --apply --source="$HOME/dev-environment/dotfiles"
```

This applies both layers (general + Claude-specific) unconditionally on the
server, plus the `CLAUDE_CODE_TMUX_TRUECOLOR=1` export that's specific to
this machine.

The first time tmux starts, press `prefix + I` (capital I) inside a tmux
session to have tpm fetch `tmux-resurrect` and `tmux-continuum` — this is a
one-time, interactive step tpm requires and can't be scripted around.

## 6. Manual: the second OpenVPN environment's config

Drop that environment's `.ovpn` file in as `client-env.ovpn`:

```sh
cp /path/to/that-environment.ovpn /opt/claude-env-vpn/config/client-env.ovpn
```

Then either re-run `server-bootstrap.sh` (it detects the file and brings
gluetun up automatically) or do it directly:

```sh
cd /opt/claude-env-vpn && docker compose up -d
```

## 7. Manual: confirm the UDM SE has no port 22 forward to WAN

In the UDM SE web UI, under port forwarding rules, confirm there is **no**
rule forwarding port 22 (or any port) to the server's LAN IP. This can't be
checked from the server itself — it has to be verified in the router's UI.
Re-check this after any UDM SE firmware upgrade, since upgrades occasionally
reset custom firewall/port-forward rules.

## 8. Manual: confirm sshd bindings survive an OS upgrade

After any `apt upgrade` that touches `openssh-server`, re-check:

```sh
sudo sshd -T | grep -i listenaddress
```

If it's reverted to binding all interfaces, re-run `server-bootstrap.sh` —
step 4's ssh logic is idempotent and will re-apply the drop-in.

An OS upgrade can also **switch ssh from `ssh.service` to socket
activation** (this is what changed in 22.10). If that happens, the old
`sshd_config` drop-in silently stops taking effect; re-running the bootstrap
script detects the new mechanism and configures `ssh.socket` instead. Always
verify with `sudo ss -tlnp | grep :22` rather than trusting `sshd -T`.

## Verification: reboot recovery

```sh
sudo reboot
```

After the server comes back up:

```sh
tmux attach -t claude-main
```

should show `claude` already running, with no manual steps — systemd's
`claude-tmux.service` starts it on boot, and `tmux-continuum` restores the
prior session layout. If a second OpenVPN environment was configured before
the reboot, `docker compose ps` in `/opt/claude-env-vpn` should show
`gluetun` and `claude-env-shell` both `Up` (`restart: unless-stopped`
handles this).
