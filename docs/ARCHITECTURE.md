# Architecture

This repo has two independent layers:

1. **General terminal and editor defaults** — shell config, Ghostty, tmux,
   general VS Code settings, common CLI tools (`ripgrep`/`fd`/`bat`/`eza`/`fzf`),
   and everyday aliases/scripts. Applies to **every** machine, including the
   work MacBook Pro.
2. **The remote Claude Code layer** — the persistent, always-on Claude Code
   host on the Ubuntu server, and the clients that reach it. Applies to
   **every machine except the work MacBook Pro**.

A single chezmoi source directory ([`dotfiles/`](../dotfiles)) manages both
layers at once: layer 1 is unconditional, layer 2 is templated out on the
work laptop's hostname. See [`.chezmoiignore.tmpl`](../dotfiles/.chezmoiignore.tmpl)
and the Claude-specific blocks in `dot_zshrc.tmpl` / `dot_ssh/config.tmpl`.

## Topology

| Device | Role | Network access |
|---|---|---|
| Ubuntu server (16GB RAM) | Sole Claude Code host, always on | Tailscale |
| Personal MacBook Air | Full client | Tailscale |
| Work MacBook Pro | Restricted client — view/edit/SSH only | OpenVPN (split-tunnel to home LAN only) |
| GL.iNet Comet Pro | Out-of-band KVM plugged into the server's hardware | Tailscale, its own independent node |
| UniFi UDM SE | Home gateway | Runs an OpenVPN server for the work laptop |
| UniFi travel router | Backup network path while traveling | — |

There's also a **second, unrelated OpenVPN connection** — a separate
third-party environment reachable only via its own OpenVPN client, used for
regular Claude Code work in that environment. This is not the same tunnel as
the OpenVPN server the UDM SE runs for the work laptop; the two must never
share a routing table (see [gluetun isolation](#gluetun-isolation) below).

## Why one always-on host

Session state (the running `claude` process, its context, any long-lived
background work) lives entirely on the Ubuntu server, inside a tmux session
kept alive by systemd. No client machine holds any of that state. Closing
the laptop — either laptop — never matters: nothing running there gets
interrupted, because nothing Claude-related is running there.

## Access paths

- **Personal MacBook Air → server**: Tailscale, direct. `claude-attach`
  SSHes to the server's Tailscale hostname and attaches to (or creates) the
  `claude-main` tmux session.
- **Work MacBook Pro → server**: OpenVPN, split-tunneled to the home
  LAN/server subnet only (see [sshd binding](#sshd-binding) below for why
  this works without WAN exposure). The work laptop never runs Claude Code
  itself — see [`docs/client-work-setup.md`](client-work-setup.md) — it's a
  view/edit/SSH client only.
- **GL.iNet Comet Pro**: an out-of-band fallback. It's a hardware KVM
  plugged directly into the server, reachable over its own independent
  Tailscale node. If the server itself becomes unreachable over SSH (network
  misconfiguration, a bad kernel update, etc.), the Comet Pro gives
  keyboard/video access to fix it without physical presence.
- **Second OpenVPN environment**: reached only through the gluetun container
  on the server, in its own network namespace, via the dedicated `claude-env`
  tmux session.

## sshd binding

sshd on the server binds only to the `tailscale0` address and its LAN
addresses (set by
[`provision/server-bootstrap.sh`](../provision/server-bootstrap.sh)) — never
a WAN address. "LAN addresses" is plural on purpose: the server has more
than one LAN interface on different VLANs, and all RFC1918 addresses on
physical interfaces get bound, so the OpenVPN-to-LAN path works regardless
of which VLAN the UDM SE routes it into. The RFC1918 filter is what enforces
the never-WAN rule — a public address would not match and so would never be
bound.

Note that on Ubuntu 22.10+ (including 24.04) ssh is socket-activated and
`sshd_config`'s `ListenAddress` is ignored entirely; binding is controlled by
`ListenStream=` in `ssh.socket`. The script detects which mechanism is live
and configures that one, because writing only an `sshd_config` drop-in on
such a system silently leaves ssh listening everywhere. This is what allows both the Tailscale path (personal
Air) and the OpenVPN-to-LAN path (work laptop) to reach it, while the server
has zero SSH surface on the public internet: even if someone had the WAN IP,
there's nothing listening there.

This depends on the UDM SE having no port-forward for port 22 (or any port)
to the server on WAN. **That's a manual check** — confirm it in the UDM SE's
web UI; it can't be verified remotely from the server itself.

## gluetun isolation

The second, unrelated OpenVPN environment's client runs inside a `gluetun`
Docker container, in its own network namespace, with its own dedicated tmux
session (`claude-env`, distinct from `claude-main`). This means:

- Its routes are entirely contained inside the container's namespace — they
  can never become the server's default route, so they can never fight
  Tailscale for it.
- Claude Code for that environment runs inside a sibling container
  (`claude-env-shell`) that shares gluetun's network stack via
  `network_mode: "service:gluetun"`, so its traffic actually goes through
  that tunnel, deliberately separate from everything else on the box.

## Definition of Done

- [ ] Closing either laptop never interrupts a Claude Code session — session
      state lives only on the server.
- [ ] The work MacBook Pro never runs Claude Code (CLI or IDE extension),
      but has the same terminal/editor defaults (Ghostty, tmux, VS Code,
      CLI tools) as every other machine.
- [ ] The two OpenVPN paths (work-laptop-to-home, and the second unrelated
      environment) never share a routing table on the server.
- [ ] A server reboot restores everything — Tailscale, sshd bindings,
      gluetun, and the `claude-main` tmux session with `claude` already
      running — with no manual steps (verify per
      [`docs/server-setup.md`](server-setup.md)).
