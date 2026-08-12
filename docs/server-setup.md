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
`ripgrep`/`fd`/`bat`/`eza`/`fzf`, Tailscale, Docker, kubectl + krew +
`kubectx`/`kubens`, Node.js, Terraform, and chezmoi, and writes the
`claude-tmux.service` systemd unit and the OpenVPN client config.

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

The unit runs [`claude-session`](../dotfiles/dot_local/bin/executable_claude-session)
rather than `claude` directly. tmux ends a session when its last command exits,
so running `claude` directly means quitting or crashing it **destroys the
session**, leaving `claude-attach` nothing to attach to. The wrapper runs
claude, then drops to a login shell and prints how to get back:

```
  ── claude exited ─────────────────────────────────────────────
     run  claude      to start it again in this window
     or   Ctrl-b d    to detach and leave the session running
  ──────────────────────────────────────────────────────────────
```

### Getting claude back after you've quit it

Once claude exits, that window stays a shell — it does not relaunch by itself.
That's deliberate: auto-restarting would make a crash-looping claude
impossible to escape, and would fight you when you quit on purpose.

- **In that window:** run `claude`.
- **Reset the whole session** (recreates it running claude, discarding any
  windows and panes you've added):

  ```sh
  sudo systemctl restart claude-tmux.service
  ```

Note that `systemctl is-active claude-tmux` is **not** proof the session
exists — any lingering process in the unit's cgroup keeps it looking active.
`verify-server.sh` checks `tmux has-session`, which is the real signal.

### Node.js / npx-based CLIs

The script installs Node.js (via NodeSource's apt repo — a system-wide LTS,
not nvm, since this is a single always-on box) and points npm's global
prefix at `~/.npm-global` so `npm install -g` needs no sudo. Both
`~/.local/bin` and `~/.npm-global/bin` are on `PATH` for every shell,
scripted or interactive (`dot_zshenv`), and the `claude-tmux.service` unit.

This is what makes `npx`-based install CLIs usable directly in the
`claude-main` session, e.g. [`skills`](https://www.npmjs.com/package/skills)
for pulling a Claude Code skill from a GitHub repo:

```sh
npx skills add <owner>/<repo>
```

### Terraform

Installed from HashiCorp's apt repo (same pattern as `eza`'s repo add): the
script adds the repo's signing key and source list once, then apt tracks and
patches Terraform like everything else installed this way (Docker,
Tailscale, Node.js).

## 6. Manual: the second OpenVPN environment's config

Drop that environment's `.ovpn` file in as the OpenVPN client config. It
embeds a private key, so it must be root-owned and not world-readable:

```sh
sudo install -m 600 -o root -g root \
  /path/to/that-environment.ovpn /etc/openvpn/client/client-env.conf
```

Re-running `server-bootstrap.sh` also picks it up (and migrates it out of the
old `/opt/claude-env-vpn/config` location if it's still there).

The tunnel is **not** enabled at boot: that environment's identity is a
certificate shared with other machines and only one connection can be live at a
time, so connecting is always deliberate.

```sh
client-vpn up      # connect
client-vpn status  # unit state + tun0 + route count
client-vpn down    # disconnect, freeing the identity for another machine
```

That environment's DNS is applied automatically. It pushes a resolver and a
search domain, but OpenVPN on Linux only *logs* those — `openvpn-systemd-resolved`
plus a systemd drop-in (both set up by `server-bootstrap.sh`) is what hands them
to `systemd-resolved`. The failure mode if that's missing is a tunnel that looks
completely healthy — routes fine, `dig @<pushed-resolver> <name>` answers — while
every internal name fails. `client-vpn status` shows the resolver in use, and
`resolvectl status tun0` reporting `Current Scopes: none` is the tell.

Other devices reach this network **through** the server rather than opening
their own connection (that identity only allows one live connection at a
time). `server-bootstrap.sh` sets that up: IP forwarding via
`/etc/sysctl.d/99-lab-routing.conf`, plus `lab-routing.service`, a oneshot that
runs `/usr/local/sbin/lab-routing-rules` to install a MASQUERADE on `tun0`,
`FORWARD` rules for `10.47.0.0/16` and the lab resolver `172.21.0.90`, and a
TCP MSS clamp on traffic entering the tunnel.

The MSS clamp is not optional decoration. `tun0`'s MTU is 1500 — the same as
the physical link — so a full-size segment plus OpenVPN's encapsulation exceeds
the real path MTU. Unclamped, the failure looks like anything but MTU: ping
works, DNS works, small requests work, and large transfers or HTTPS pages hang
forever. It uses `--set-mss 1350` rather than `--clamp-mss-to-pmtu`, because
clamping derives the value from the outgoing route's MTU — `tun0`'s 1500 —
which yields MSS 1460, exactly the value that blackholes.

Nothing is added to this box's routing table: both prefixes already sit inside
routes the tunnel installs. Only forwarding and NAT were missing.

**This does not go through `ufw`, on purpose.** ufw is installed here but
disabled (`ENABLED=no` in `/etc/ufw/ufw.conf`), which is easy to misread —
`systemctl is-active ufw` still says `active`, because the unit is a oneshot
that reads that flag and exits. While disabled ufw applies nothing, so
`before.rules` and `ufw route` rules are written but inert. Enabling it would
turn on `INPUT DROP` on a box only reachable over SSH/Tailscale/mosh, which is
a bigger decision than routing one subnet. If you ever do enable ufw, re-run
`systemctl restart lab-routing.service` afterwards — enabling ufw rebuilds the
filter table and drops these rules.

`verify-server.sh` checks all of it under "Lab subnet routing", asking the
kernel with `iptables -C` rather than trusting any config file — that is
exactly the failure the ufw attempt hid. Run it **as yourself, never under
`sudo`**: it inspects your shell, PATH and dotfiles, none of which root has,
and it now refuses to start as root. The checks that need root escalate on
their own and will ask for a password.

The client side is manual and lives in `docs/client-work-setup.md` §6: static
routes on the UDM SE pointing at this box, and a `/etc/resolver/set.lab` entry
on the laptop. The older `browser-vpn` SOCKS5 proxy is documented there too,
as the fallback for networks where the routed path isn't available.

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

## Dev session log

A standalone, **private** `~/dev-log` git repo, pushed to a private GitHub
repo (`warroyo/dev-log`) via the `origin` remote, collects short, curated
notes from Claude Code sessions across every project on this machine —
decisions, pitfalls, reusable commands, follow-ups. It's raw material for
later blog posts and skills, not a transcript dump. See
[`~/dev-log/README.md`](../../dev-log/README.md) for the entry format.

Two chezmoi-managed, server-only files handle it, applied by
`server-bootstrap.sh` like the rest of the dotfiles — nothing manual:

- The shared writer
  ([`dev-log-entry`](../dotfiles/dot_local/bin/executable_dev-log-entry)),
  invoked by...
- ...the on-demand
  [`/log-session`](../dotfiles/dot_claude/commands/log-session.md) command,
  the only way entries get written.

Usage: run `/log-session` (optionally with a note, e.g.
`/log-session remember the flaky DNS workaround`) at a natural stopping
point, or when Claude proactively suggests it per the `CLAUDE.md` priming
below. It drafts an entry from the conversation so far, derives the project
slug from the current repo's directory name, and pipes the entry to
`dev-log-entry`, which appends it to `entries/YYYY-MM-DD-<slug>.md`,
commits, and pushes to `origin` — best-effort, so a write never fails just
because the box is offline. Pushing relies on `gh` being authenticated
(`gh auth login`); the git credential helper for `github.com`/
`gist.github.com` is wired to `gh` in
[`dot_gitconfig.platform.tmpl`](../dotfiles/dot_gitconfig.platform.tmpl) so
non-interactive pushes work without a stored token.

A note in the global [`CLAUDE.md`](../dotfiles/dot_claude/CLAUDE.md) primes
every session to keep a running sense of what's worth keeping and
proactively suggest `/log-session` at a natural point — priming, not
automatic writing. An earlier version tried a `Stop`-hook safety net
instead, but Claude Code's `Stop` event fires once per *turn*, not once per
session, which doesn't map cleanly onto `claude-main` being an always-on
tmux session that may never see a true "session end" — it would have fired
(and had to be debounced) dozens of times a day. `CLAUDE.md` guidance,
loaded automatically at the start of every session, does the same priming
job without an event/script to maintain.

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
prior session layout.

The second OpenVPN environment is deliberately *not* restored by a reboot —
it is on-demand only, because its identity is shared with other machines.
Bring it back with `client-vpn up` when you need it.
