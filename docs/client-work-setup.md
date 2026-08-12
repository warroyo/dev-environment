# Work MacBook Pro setup

**The Claude Code CLI and IDE extension are never installed on this machine,
and it never joins the tailnet.** It's a pure view/edit/SSH client — Ghostty,
Mosh, VS Code Remote-SSH. Everything else in the general layer (shell
config, tmux, VS Code defaults, common CLI tools) applies here exactly as
it does on the server and the personal Air; this machine is a normal
chezmoi target, not a special case for that layer.

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

You get the `claude-main` tmux session with `claude` already running **on the
server**. Nothing executes locally — this is exactly the intended way to use
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
2. On the UDM SE (Settings → Routing → **Static Routes**), two routes with the
   server's LAN IP as the next hop: `10.47.0.0/16` and `172.21.0.90/32`.
3. Whatever carries you home — Teleport on a UniFi travel router, or the
   split-tunnel OpenVPN profile from §2 — has to actually pass those routes on.
   Check in this order and stop at the first that works:
   - the gateway already advertises its static routes to the tunnel — nothing
     to do;
   - add the same two static routes on the travel router, pointing into its
     Teleport interface;
   - set the travel router's Teleport connection to route all traffic home,
     which makes the specific routes moot at the cost of sending general
     browsing over the tunnel.

### Split DNS for `set.lab` — automated

`client-work-bootstrap.sh` installs this; there is nothing to do by hand. It
writes `/etc/resolver/set.lab` (via `provision/lib/lab-dns.sh`) pointing
`*.set.lab` at `172.21.0.90`, and flushes the DNS cache. Only that zone is
affected — everything else keeps using the machine's normal resolver, so
general DNS never depends on the tunnel being up. That is why `172.21.0.90/32`
is in the routed set.

The file carries `timeout 3` deliberately. It applies unconditionally, so off
this network every `*.set.lab` lookup goes to an unreachable resolver; the
short timeout keeps that a brief pause rather than a multi-second hang.

**Testing gotcha:** `dig` and `nslookup` **ignore** `/etc/resolver` entirely —
they talk to a nameserver directly. They will report failure while Safari,
Chrome, `curl` and `ping` all work fine. Use the system resolver instead:

```sh
dscacheutil -q host -a name <host>.set.lab
```

If MDM overrides `/etc/resolver`, the fallback is to move the split into the
network instead: run `dnsmasq` on the server with
`server=/set.lab/172.21.0.90` bound to its LAN address, and point the travel
router's DHCP DNS at the server.

### Verify

With Teleport up and **no proxy configured anywhere**:

```sh
netstat -rn | grep 10.47                 # route present, via the tunnel
traceroute 10.47.<host>                  # first hop is the tunnel, not the local gw
dscacheutil -q host -a name <name>.set.lab
```

### Fallback: the SOCKS proxy

`browser-vpn` still exists for networks where the routed path isn't available
— someone else's wifi, no travel router. It's slower by construction (SOCKS
over SSH, and over a VPN it becomes TCP inside TCP), so it's the fallback, not
the default.

```sh
browser-vpn up      # opens socks5://127.0.0.1:1080 to claude-server
browser-vpn status
browser-vpn down    # closes it; does not touch the server's client-vpn tunnel
```

`CLAUDE_SERVER_HOST` and `BROWSER_VPN_PORT` work the same as elsewhere if you
need non-default values.

Then in the browser, install Zero Omega Proxy Switcher (or similar) and add a SOCKS5 proxy at
`127.0.0.1:1080` with **"Proxy DNS via SOCKS5" enabled** — without it, hostname
lookups happen locally instead of on the server and internal names won't
resolve. Scope it to a URL pattern matching that VPN's domain(s) so only that
traffic is proxied; everything else browses normally, unaffected. Turn it back
to "direct" when you go back to the routed path.
