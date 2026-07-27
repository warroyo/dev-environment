# Server setup (role: `server`)

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

The script now also installs the Claude Code CLI, applies the dotfiles via
chezmoi, and installs the tmux plugins — those are no longer separate manual
steps.

## 2. Authenticate the Claude Code CLI

Installation is handled by the script. The **first-run login is an
interactive browser/OAuth flow** and stays manual — run `claude` once and
follow the prompts.

Because the server is headless, the shell config aliases `$BROWSER` to print
URLs rather than launch a browser; Ghostty renders them as clickable links,
so clicking opens the browser on your Mac. See
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md).

## 3. `tailscale up`

Either supply an auth key and let the script do it:

```sh
TAILSCALE_AUTHKEY=tskey-auth-... ./provision/server-bootstrap.sh
```

(generate the key at
<https://login.tailscale.com/admin/settings/keys> — the key itself has to
come from the web UI), or do it interactively:

```sh
sudo tailscale up
```

Confirm the machine shows up in your tailnet and note its Tailscale hostname
(should be `ubuntu-home`; used throughout `dotfiles/.chezmoidata.yaml` and
the SSH config template).

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

You should see one entry per LAN address plus the Tailscale address, and
**no** `0.0.0.0:22` or `*:22`. A wildcard bind means ssh is still listening
on every interface.

The script binds **every** RFC1918 address on a physical interface, not just
the one on the default route — this server has more than one LAN interface
(ethernet and wifi, on different VLANs), and the work laptop's
OpenVPN-to-LAN traffic can arrive on either depending on how the UDM SE
routes between the VPN pool and each VLAN. Binding all of them means the
listener is never the reason a path fails. `docker0`, loopback and
`tailscale0` are excluded (Tailscale is added explicitly).

**These addresses must be DHCP reservations or static.** The bind is written
as a literal address, and `FreeBind` means ssh still *starts* successfully
if an address is gone — it just silently stops accepting on it. If you
change a reservation on the UDM SE, re-run this script.

### If the work laptop can reach the server but SSH hangs

That's a routing symptom, not a binding one. The server's default route
exits via one VLAN's gateway, so a request arriving on the *other* LAN
interface gets its reply sent back out the default route — an asymmetric
flow that a stateful firewall may drop. Check that the UDM SE permits the
VPN pool to reach whichever VLAN you're targeting, and prefer connecting to
the address on the same VLAN the OpenVPN pool routes into.

## 5. Dotfiles and tmux plugins — automated

Both are done by the bootstrap script; nothing to run by hand.

It applies both layers (general + Claude-specific) on the server, including
the `CLAUDE_CODE_TMUX_TRUECOLOR=1` export specific to this machine, then
installs `tmux-resurrect` and `tmux-continuum` via tpm's `install_plugins`
(the scripted equivalent of pressing `prefix + I`).

One ordering detail the script handles: if `claude-tmux.service` started a
tmux server at boot *before* `~/.tmux.conf` existed, that server never
sourced the config and tpm aborts with "Tmux Plugin Manager not configured
in tmux.conf". The script runs `tmux source-file ~/.tmux.conf` against the
live server first, which both fixes tpm and makes the new settings take
effect in `claude-main` without restarting your session.

### Where the session starts, and why it stays alive

`claude-main` starts in `~/workspace`. Override it per-run:

```sh
CLAUDE_WORKDIR=~/some/project ./provision/server-bootstrap.sh
```

This has to be set explicitly: systemd defaults `WorkingDirectory` to `/` for
services, so without it the session — and everything you run in it — starts at
the filesystem root. `~/workspace` rather than `$HOME` keeps Claude Code's
read/write scope off your dotfiles, `~/.ssh` and everything else in the home
directory.

**The trust prompt matters here.** Claude Code asks "is this a project you
trust?" the first time it runs in a directory and requires an interactive
answer. systemd starts the session detached with nobody to answer, so claude
prints the prompt, gets no input, and exits — leaving an empty session. The
script pre-records the trust decision for `CLAUDE_WORKDIR` in `~/.claude.json`
(backing it up first) so this doesn't happen.

That file isn't a documented interface. If its format changes in an update the
pre-seeding silently stops working and the prompt comes back — the session
still survives thanks to the shell fallback below, you'd just answer once by
hand.

The unit runs `claude; exec $SHELL -l` rather than just `claude`. tmux ends a
session when its last command exits, so running `claude` directly means
quitting or crashing it **destroys the session**, leaving `claude-attach`
nothing to attach to. Falling through to a login shell keeps `claude-main`
alive; just run `claude` again inside it.

Note that `systemctl is-active claude-tmux` is **not** proof the session
exists — any lingering process in the unit's cgroup keeps it looking active.
`verify-server.sh` checks `tmux has-session`, which is the real signal.

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

## Verification: automated health check

```sh
./provision/verify-server.sh
```

Read-only, changes nothing, exits non-zero if anything FAILs. Checks tooling,
dotfiles (including that chezmoi-managed files haven't drifted, and that
`~/.ssh/config` is `0600`), tmux plugins, Tailscale, the ssh bindings
(flagging any wildcard bind or unbound LAN address), and the persistent
session. Run it after a reboot or an OS upgrade.

WARNs don't fail the run — an unconfigured second OpenVPN environment is
expected if you don't use it.

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
