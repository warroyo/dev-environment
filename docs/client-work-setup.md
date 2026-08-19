# Work MacBook Pro setup

**The Claude Code CLI and IDE extension are never installed on this machine,
and it never joins the tailnet.** It's a pure view/edit/SSH client — Ghostty,
Mosh, VS Code Remote-SSH. Everything else in the general layer (shell
config, tmux, herdr, VS Code defaults, common CLI tools) applies here exactly
as it does on the server and the personal Air; this machine is a normal
chezmoi target, not a special case for that layer.

`herdr` is in that general layer for the same reason `tmux` and `mosh` are: it
is a multiplexer client that draws terminals owned by the server, and it
neither bundles nor executes Claude Code. The bootstrap's verification step at
the end checks the constraint itself — that no `claude` is installed — rather
than filtering on tool names.

## 0. What "no Claude Code here" does and doesn't mean

The rule is about **installation and local execution**, not about access.
Nothing on this machine may install or run `claude`. Attaching over SSH to the
session running on the server is fine — it's what this laptop is for — so
`claude-attach` and `claude-env` are installed here like everywhere else. They
run `ssh` locally and `claude` on the server.

| Ships here | Doesn't |
|---|---|
| `claude-attach`, `claude-env`, `claude-vscode`, the `ca`/`ce`/`cv` aliases — SSH clients (`claude-vscode` also runs the local `code` CLI, which is fine here) | `claude-session` — the wrapper that execs `claude` in the current shell (server only) |
| `70_work_guard.sh` — exports `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1` | the CLI itself, by any install path |
| | the Claude Code VS Code extension |

There's no placeholder to fill in. `client-work-bootstrap.sh` declares this
machine's role as `work` in `~/.config/chezmoi/chezmoi.toml`. If the role were
somehow missing it falls back to `restricted`, which resolves identically — the
scheme **fails closed**.

The bootstrap script ends by verifying the actual constraint: no `claude` on
`PATH`, none at the known install locations (`~/.local/bin/claude`,
`~/.claude/local/claude`, the Homebrew prefixes), no `anthropic.claude-code`
in `code --list-extensions`, and no `claude-session`. Re-run it any time to
re-check:

```sh
./provision/client-work-bootstrap.sh
chezmoi ignored     # role exclusions: .local/bin/claude-session, paste-image, 60_browser.sh
```

Your git identity is read from `~/.gitconfig.local`, which the bootstrap seeds
from whatever this machine already had — applying these dotfiles won't change
how your work commits are attributed.

## 1. Run the bootstrap script

```sh
git clone <this-repo-url> ~/dev-environment
cd ~/dev-environment
./provision/client-work-bootstrap.sh
```

Installs Ghostty, Mosh, chezmoi, and VS Code via Homebrew — **no Tailscale,
no Claude Code** — sets `claude-code.autoInstallIdeExtension: false` in VS
Code's settings so opening an integrated terminal there never silently
installs the Claude Code extension, and ends with `chezmoi apply`. chezmoi
itself runs normally here; `.chezmoiignore.tmpl` keeps `claude-session` and
`paste-image` off this machine.

## 2. Manual: install the OpenVPN client and import the split-tunnel profile

Install an OpenVPN client (e.g. Tunnelblick or the OpenVPN Connect app).
Get the split-tunnel profile from the UDM SE (Settings → VPN → Servers →
the OpenVPN server instance) and import it. Confirm it's split-tunneled —
routes to the home LAN/server subnet only, **no `redirect-gateway`** — so it
never fights a corporate VPN's routing when both are active. This is a
UDM SE web UI step and has to be done interactively.

## 3. Config naming convention

Two unrelated OpenVPN configs exist across this whole setup — don't mix
them up:

| File | Used on | Purpose |
|---|---|---|
| `home-server.ovpn` | Work MacBook Pro | Reach `ubuntu-home` over the UDM SE's split-tunnel OpenVPN server |
| `client-env.conf` | Ubuntu server (`/etc/openvpn/client/`) | The second, unrelated third-party environment |

They're for entirely different networks and neither is a fallback for the
other.

## 4. Verify

```sh
ssh <server-LAN-IP>   # over the OpenVPN-to-LAN path, once connected
```

Use the server's **LAN IP**, not `ubuntu-home`. That name is provided by
Tailscale MagicDNS, which this machine deliberately doesn't have — it will
not resolve here unless you've added a local DNS record for it on the
UDM SE. The managed `~/.ssh/config` also has no `Host claude-server` block
here: that block's `HostName` is the tailnet name, so it's skipped for this
role by `private_dot_ssh/private_config.tmpl`.

## 5. Point `claude-attach` at the server

`claude-attach` and `claude-env` are installed here, and both SSH to
`$CLAUDE_SERVER_HOST` (default `claude-server`) — a name that resolves to
nothing on this machine until you define it. Add the entry to
`~/.ssh/config.local`, which chezmoi doesn't manage and the managed config
includes first, so it wins:

```sshconfig
Host claude-server
  HostName 192.168.1.50      # the server's LAN IP, reachable over OpenVPN
  User your-login-name
```

Then, with the VPN up:

```sh
claude-attach     # or the alias: ca
```

You get the `claude-main` herdr workspace with `claude` already running **on
the server**. The herdr client runs here, but it only draws terminals the
server owns — nothing Claude-related executes locally. Detach with `Ctrl-b q`.
This is exactly the intended way to use
Claude Code from this laptop, and it's why the CLI never needs to be installed
here.

Alternatively, set `export CLAUDE_SERVER_HOST=192.168.1.50` in `~/.zsh.local`
and skip the SSH entry, or add a local DNS record on the UDM SE so
`ubuntu-home` resolves over the VPN.

## 6. Reach the server's other VPN (`client-env`) as a routed network

That environment's identity only allows **one live connection at a time**
(`docs/server-setup.md`, §6). If this laptop opened its own client for it,
that would kick whichever connection is already live. So the server keeps the
one connection and **routes** `10.47.0.0/16` and the lab resolver
`172.21.0.90` for LAN clients — including anything arriving over the UDM SE's
Teleport tunnel. No proxy, no browser extension: the laptop just has a route.

Only those two prefixes are routed. The tunnel also pushes `10.0.0.0/10`,
which contains the home LAN and quite possibly whatever wifi you're sitting
on, and `172.17.0.0/24`, which is Docker's usual bridge. Neither belongs in a
laptop's routing table.

### Prerequisites

1. On the server: `client-vpn up` (e.g. over `ca`/`claude-attach`), and
   `lab-routing.service` running — `./provision/verify-server.sh` reports the
   "Lab subnet routing" section clean. Run `server-bootstrap.sh` if it doesn't.
2. On the UDM SE (Settings → Routing → **Static Routes**), one route with the
   server's LAN IP as the next hop: `10.47.0.0/16`. The lab resolver needs no
   route of its own any more — see the split-DNS section below.
3. Whatever carries you home — Teleport on a UniFi travel router, or the
   split-tunnel OpenVPN profile from §2 — has to actually pass that route on.
   Check in this order and stop at the first that works:
   - the gateway already advertises its static routes to the tunnel — nothing
     to do;
   - add the same static route on the travel router, pointing into its
     Teleport interface;
   - set the travel router's Teleport connection to route all traffic home,
     which makes the specific route moot at the cost of sending general
     browsing over the tunnel.

### Split DNS for `set.lab` — automated

`client-work-bootstrap.sh` installs this; there is nothing to do by hand. It
writes `/etc/resolver/set.lab` (via `provision/lib/lab-dns.sh`) pointing
`*.set.lab` at the **server's LAN address on port 5300**, and flushes the DNS
cache. Only that zone is affected — everything else keeps using the machine's
normal resolver, so general DNS never depends on the tunnel being up.

The file carries `timeout 3` deliberately. It applies unconditionally, so off
this network every `*.set.lab` lookup goes to an unreachable resolver; the
short timeout keeps that a brief pause rather than a multi-second hang.

#### Why port 5300 and not the lab resolver on 53

This used to point straight at `172.21.0.90:53` and let the server route the
packets. It worked on the home LAN and broke the first time it was used from a
travel router, in a way worth recognising again:

- `10.47.x.x` was reachable, so the tunnel was obviously fine.
- `traceroute 172.21.0.90` walked the whole path and into the tunnel, so the
  route was obviously fine.
- Every `*.set.lab` lookup still failed.

The UDM was DNAT'ing **anything on port 53** to itself for clients arriving
over Teleport — regardless of the address they were sent to. The reply came
back with `172.21.0.90` as its source, `NXDOMAIN`, and a root-server SOA.

The tell is latency, not the answer. The interceptor sits nearer than the real
resolver, so it replies *faster* than the path allows:

```
Mac    → "172.21.0.90"  NXDOMAIN, authority = a.root-servers.net   25 ms
server → 172.21.0.90    auto.gpu.set.lab A 10.47.0.224, aa flag    47 ms
```

Hop 4 of the traceroute alone is 70 ms and the lab is past it, so nothing
beyond hop 3 can answer in 25 ms. A TCP query is the quick confirmation: a
handshake plus query cannot beat the round-trip time either.

Traceroute proves a **route**. It says nothing about a **port** — it never
sends one on 53. So the address used solely for DNS looked dead while every
other address on the same route worked.

The fix is to stop putting port 53 on the wire. `server-bootstrap.sh` runs
dnsmasq on the server listening on **5300**, forwarding only `set.lab` into
the tunnel (`no-resolv`, so it is not an open resolver for anything else), and
the client asks that instead. Nothing on a borrowed network redirects 5300,
so this survives hotel and conference wifi, which do the same thing the UDM
did and offer no admin panel to turn it off.

**Testing gotcha:** `dig` and `nslookup` **ignore** `/etc/resolver` entirely —
they talk to a nameserver directly. They will report failure while Safari,
Chrome, `curl` and `ping` all work fine. Use the system resolver instead:

```sh
dscacheutil -q host -a name <host>.set.lab
dig -p 5300 @<server-LAN-IP> <host>.set.lab   # the same query by hand
```

If MDM overrides `/etc/resolver`, the fallback is to point the travel router's
DHCP DNS at the server — though that needs dnsmasq moved back to 53, which
reintroduces the interception problem on any network that does this.

### Verify

With Teleport up and **no proxy configured anywhere**:

```sh
netstat -rn | grep 10.47                 # route present, via the tunnel
traceroute 10.47.<host>                  # first hop is the tunnel, not the local gw
dig -p 5300 @<server-LAN-IP> auto.gpu.set.lab   # expect the aa flag
dscacheutil -q host -a name <name>.set.lab
```

If the `dig` answers but `dscacheutil` doesn't, the problem is
`/etc/resolver/set.lab`, not the network — re-run `client-work-bootstrap.sh`
and `sudo killall -HUP mDNSResponder`.

### Removed: the SOCKS proxy

There used to be a `browser-vpn` script here — an `ssh -D` SOCKS5 proxy to the
server, driven by a browser extension. The routed path replaced it and it is
gone. If you find a reference to it, or a Zero Omega profile still pointed at
`127.0.0.1:1080`, both are stale.
