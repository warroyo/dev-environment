# Architecture

This repo has two independent layers:

1. **General terminal and editor defaults** — shell config, Ghostty, tmux,
   general VS Code settings, common CLI tools (`ripgrep`/`fd`/`bat`/`eza`/`fzf`,
   plus `kubectl`/krew/`kubectx`), and everyday aliases/scripts. Applies to
   **every** machine, including the restricted work laptop.
2. **The remote Claude Code layer** — the persistent, always-on Claude Code
   host, and the clients that reach it. The *host* half is the server alone.
   The *client* half — `claude-attach`, `claude-env`, `claude-vscode`, their
   aliases — applies everywhere, including the work laptop: those are SSH
   clients that execute nothing Claude-related locally, and reaching the
   server is what a client machine is for.

A single chezmoi source directory ([`dotfiles/`](../dotfiles)) manages both at
once: layer 1 is unconditional, layer 2 is excluded by
[`.chezmoiignore.tmpl`](../dotfiles/.chezmoiignore.tmpl) based on the machine's
declared **role**.

## Roles

Machines are described by role, not by name. Each bootstrap script writes its
role to `~/.config/chezmoi/chezmoi.toml`, outside the repo.

| Role | Purpose | Reaches the server via |
|---|---|---|
| `server` | Sole Claude Code host, always on | — |
| `personal` | Full client | Mesh VPN |
| `work` | Restricted client — never *installs or runs* Claude Code locally; attaches to the server's session over SSH like any client | Split-tunnel VPN to the LAN |
| `restricted` | Default for any undeclared machine; same as `work` | — |

**What "restricted" restricts.** The line is local execution, not the name of a
file. A restricted machine never has the CLI or the IDE extension installed and
gets no file that runs `claude` in its own shell (`claude-session` is server
only). It does get the SSH clients that attach to the session on the server.
Enforcement lives where an install would actually happen: no install step in
`client-work-bootstrap.sh` (which verifies the absence at the end),
`claude-code.autoInstallIdeExtension: false` in the managed VS Code settings,
and `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1` from `70_work_guard.sh`.

Two further pieces sit outside the role system:

- An **out-of-band KVM** attached to the server's hardware, on its own
  independent mesh-VPN node. It's the recovery path when the server is
  unreachable over SSH.
- A **second, unrelated VPN environment** — a separate third-party network
  reached only through its own OpenVPN client, used for Claude Code work in
  that environment. It is *not* the same tunnel the work laptop uses to reach
  the LAN (see [the second VPN environment](#the-second-vpn-environment)).

## Why one always-on host

Session state — the running `claude` process, its context, any long-lived
background work — lives entirely on the server, in a tmux session kept alive by
systemd. No client holds any of it. Closing a laptop never matters, because
nothing Claude-related runs on a laptop.

## Access paths

- **`personal` → server**: mesh VPN, direct. `claude-attach` SSHes to the
  server and attaches to (or creates) the `claude-main` tmux session.
- **`work` → server**: split-tunnel VPN routed to the LAN only — no
  `redirect-gateway`, so it never fights a corporate VPN's routing. Same
  `claude-attach` workflow as `personal`, but `claude-server` has to be defined
  in `~/.ssh/config.local` because the managed tailnet Host block is skipped for
  this role. Claude Code itself is never installed on it; see
  [`docs/client-work-setup.md`](client-work-setup.md).
- **Out-of-band KVM**: keyboard/video access to the server's hardware when SSH
  is unavailable — a bad kernel update, a network misconfiguration — without
  needing physical presence.
- **Second VPN environment**: an on-demand OpenVPN client on the server,
  reached via the dedicated `claude-env` tmux session.
- **Phone → server**: a Telegram bot on the server
  (`claude-telegram-bot.service`) starts a detached tmux session running
  `claude --remote-control` in a directory under `~/workspace`; the
  conversation then happens in the Claude app over Remote Control. This is the
  one access path that isn't SSH, so it's also the one with a credential that
  can leak — the bot answers **only** chat ids in an allow-list kept in
  `~/.secrets/telegram-bot`, and drops everything else without replying. It
  starts and stops sessions; it never relays messages. See
  [`docs/server-setup.md`](server-setup.md#9-manual-the-telegram-bot-start-sessions-from-your-phone).

## sshd binding

sshd binds only to the server's mesh-VPN address and its LAN addresses, set by
[`provision/server-bootstrap.sh`](../provision/server-bootstrap.sh) — never a
WAN address. Both remote paths therefore work while the server has no SSH
surface on the public internet: even with the WAN address, nothing is listening.

"LAN addresses" is plural on purpose. The server has more than one LAN
interface on different VLANs, and every RFC1918 address on a physical interface
gets bound, so the VPN-to-LAN path works regardless of which VLAN the gateway
routes it into. **The RFC1918 filter is what enforces the never-WAN rule** — a
public address wouldn't match the filter, so it can never be bound.

Two implementation notes that are easy to get wrong:

- On Ubuntu 22.10+ ssh is **socket-activated**, and `sshd_config`'s
  `ListenAddress` is ignored entirely — binding comes from `ListenStream=` in
  `ssh.socket`. Writing only an `sshd_config` drop-in on such a system silently
  leaves ssh listening everywhere. The script detects which mechanism is live
  and configures that one.
- Binding a mesh-VPN address that isn't assigned yet at boot would make ssh
  fail to start and take out the LAN path too, so the config permits non-local
  binds.

This all assumes **the gateway forwards no ports to the server on WAN**. That's
a manual check in the gateway's UI — it can't be verified from the server.

## The second VPN environment

That environment's OpenVPN client runs **directly on the server** under
systemd (`openvpn-client@client-env`), with its own tmux session (`claude-env`,
distinct from `claude-main`).

It was originally isolated inside a `gluetun` container in its own network
namespace, on the stated constraint that this client and the mesh VPN must
never share a routing table. That constraint was written for a full-tunnel
config and does not describe the actual `client-env.ovpn`:

- The file sets no `redirect-gateway`, so it never touches the default route.
- The mesh VPN is a `/32` resolved through its own routing table (`ip rule`
  5270 → table 52), and `100.64/10` overlaps none of the pushed subnets.
- The LAN's `10.10.2.0/24` is more specific than the pushed `10.0.0.0/10`, so
  the LAN and the default gateway keep winning.

The one genuine collision was the pushed `172.17.0.0/24` against Docker's
default bridge `172.17.0.0/16`: `/24` beats `/16`, so the tunnel would have
captured exactly the range `docker0` hands out. `server-bootstrap.sh` moves
`docker0` via `/etc/docker/daemon.json` instead.

Running on the host also means Claude Code in this session gets the real home
directory, ssh keys, gitconfig and editor — none of which existed in the
container.

### Connecting is always explicit

The tunnel is **not enabled at boot**. That environment's identity is a
certificate shared with other machines, and the server accepts only one live
connection per identity, so auto-connecting would silently take the session
from whoever else is on it:

```sh
client-vpn up      # connect
client-vpn status  # unit state + tun0 + route count
client-vpn down    # disconnect, freeing the shared identity
```

`claude-env` warns when the tunnel is down but never brings it up, for the same
reason.

### The server routes that environment for other machines

Because only one connection to it may exist, the server holds it and forwards
for everyone else: `10.47.0.0/16` and the lab resolver `172.21.0.90` are routed
out `tun0`, masqueraded so the lab — which has no route back to this LAN, let
alone to the gateway's Teleport pool — can answer. The forward rules are scoped
by destination rather than by inbound interface on purpose: this box has LAN
legs on two VLANs, and pinning them to one silently broke clients on the other
(requests forwarded, every reply dropped). The
work laptop reaches the subnet over the gateway. `lab-routing.service` owns the
`FORWARD` and NAT rules and reinstalls them on boot; `verify-server.sh` checks
them against the kernel.

Names are a separate mechanism, because routing alone was not enough. dnsmasq
runs here on **port 5300** forwarding `set.lab` into the tunnel, and clients
point `/etc/resolver/set.lab` at this box rather than at the lab resolver.
Pointing at `172.21.0.90:53` directly is what it did first, and it failed the
moment the laptop sat behind a gateway that DNAT's all port-53 traffic to
itself — the route was intact and traceroute proved it, but traceroute never
sends anything on 53. See [`docs/client-work-setup.md`](client-work-setup.md)
§6 for the full diagnosis; the reusable part is that the interceptor answers
*faster* than the real resolver can, so latency is the tell.

The rules are installed directly rather than through `ufw`, which is present
but disabled here — see [`docs/server-setup.md`](server-setup.md) §6 for why
that is not as obvious as `systemctl is-active ufw` makes it look.

Only those two prefixes, deliberately: the pushed `10.0.0.0/10` and
`172.17.0.0/24` are exactly the collisions described above, and handing them to
a laptop that has to keep working on other people's networks would move the
problem rather than solve it.

This replaced an `ssh -D` SOCKS proxy (`browser-vpn`), which is SOCKS over SSH
over the gateway's WireGuard tunnel — TCP inside TCP, one full round trip per
handshake and per name lookup. It's kept as a fallback for networks where the
routed path isn't available; see
[`docs/client-work-setup.md`](client-work-setup.md).

## Definition of Done

- [ ] Closing a laptop never interrupts a Claude Code session — session state
      lives only on the server.
- [ ] The work laptop never has Claude Code installed (CLI or IDE extension)
      and never runs it locally, but has the same terminal/editor defaults as
      every other machine and can attach to the server's session over SSH.
- [ ] The two VPN paths never contend for the server's default route.
- [ ] A server reboot restores everything — mesh VPN, ssh bindings,
      and the `claude-main` tmux session with `claude` already running — with
      no manual steps (verify per [`docs/server-setup.md`](server-setup.md)).
- [ ] The role scheme fails closed: a machine that never declared a role gets
      the general layer only.
