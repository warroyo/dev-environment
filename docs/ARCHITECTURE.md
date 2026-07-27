# Architecture

This repo has two independent layers:

1. **General terminal and editor defaults** — shell config, Ghostty, tmux,
   general VS Code settings, common CLI tools (`ripgrep`/`fd`/`bat`/`eza`/`fzf`),
   and everyday aliases/scripts. Applies to **every** machine, including the
   restricted work laptop.
2. **The remote Claude Code layer** — the persistent, always-on Claude Code
   host, and the clients that reach it. Applies to every machine **except** the
   work laptop.

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
| `work` | Restricted client — view/edit/SSH only, never runs Claude Code | Split-tunnel VPN to the LAN |
| `restricted` | Default for any undeclared machine; same as `work` | — |

Two further pieces sit outside the role system:

- An **out-of-band KVM** attached to the server's hardware, on its own
  independent mesh-VPN node. It's the recovery path when the server is
  unreachable over SSH.
- A **second, unrelated VPN environment** — a separate third-party network
  reached only through its own OpenVPN client, used for Claude Code work in
  that environment. It is *not* the same tunnel the work laptop uses to reach
  the LAN, and the two must never share a routing table (see
  [gluetun isolation](#gluetun-isolation)).

## Why one always-on host

Session state — the running `claude` process, its context, any long-lived
background work — lives entirely on the server, in a tmux session kept alive by
systemd. No client holds any of it. Closing a laptop never matters, because
nothing Claude-related runs on a laptop.

## Access paths

- **`personal` → server**: mesh VPN, direct. `claude-attach` SSHes to the
  server and attaches to (or creates) the `claude-main` tmux session.
- **`work` → server**: split-tunnel VPN routed to the LAN only — no
  `redirect-gateway`, so it never fights a corporate VPN's routing. This
  machine never runs Claude Code; see
  [`docs/client-work-setup.md`](client-work-setup.md).
- **Out-of-band KVM**: keyboard/video access to the server's hardware when SSH
  is unavailable — a bad kernel update, a network misconfiguration — without
  needing physical presence.
- **Second VPN environment**: reached only through the gluetun container on the
  server, via the dedicated `claude-env` tmux session.

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

## gluetun isolation

The second VPN environment's client runs inside a `gluetun` Docker container,
in its own network namespace, with its own tmux session (`claude-env`, distinct
from `claude-main`):

- Its routes stay inside the container's namespace, so they can never become
  the server's default route and can never fight the mesh VPN for it.
- Claude Code for that environment runs in a sibling container
  (`claude-env-shell`) sharing gluetun's network stack via
  `network_mode: "service:gluetun"`, so its traffic genuinely goes through that
  tunnel, deliberately separate from everything else on the box.

## Definition of Done

- [ ] Closing a laptop never interrupts a Claude Code session — session state
      lives only on the server.
- [ ] The work laptop never runs Claude Code (CLI or IDE extension), but has
      the same terminal/editor defaults as every other machine.
- [ ] The two VPN paths never share a routing table on the server.
- [ ] A server reboot restores everything — mesh VPN, ssh bindings, gluetun,
      and the `claude-main` tmux session with `claude` already running — with
      no manual steps (verify per [`docs/server-setup.md`](server-setup.md)).
- [ ] The role scheme fails closed: a machine that never declared a role gets
      the general layer only.
