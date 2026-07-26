# Work MacBook Pro setup

**This machine never installs or runs Claude Code (CLI or IDE extension),
and never joins the tailnet.** It's a pure view/edit/SSH client — Ghostty,
Mosh, VS Code Remote-SSH. Everything else in the general layer (shell
config, tmux, VS Code defaults, common CLI tools) applies here exactly as
it does on the server and the personal Air; this machine is a normal
chezmoi target, not a special case for that layer.

## 0. Before you start: set the real hostname

`dotfiles/.chezmoidata.yaml` has one placeholder for this machine:

```yaml
hostnames:
  workLaptop: "REPLACE_WITH_WORK_LAPTOP_HOSTNAME"
```

Run `hostname` on this laptop, paste the exact output in, and commit
*before* running `chezmoi apply` here.

This matters more than it looks: if `workLaptop` doesn't match,
`.chezmoiignore.tmpl` won't match this host and **the Claude-specific
scripts get installed here** — that exclusion is the only thing enforcing
the constraint.

(Git identity is the same on every machine, so there's nothing per-machine
to set for it.)

Verify the exclusion actually took effect before trusting it:

```sh
chezmoi ignored          # should list .local/bin/claude-attach, claude-env, paste-image
chezmoi execute-template '{{ .chezmoi.hostname }}'   # should match workLaptop exactly
```

The bootstrap script also checks for leaked files at the end and errors
loudly if any are present.

## 1. Run the bootstrap script

```sh
git clone <this-repo-url> ~/dev-environment
cd ~/dev-environment
./provision/client-work-bootstrap.sh
```

Installs Ghostty, Mosh, chezmoi, and VS Code via Homebrew — **no Tailscale,
no Claude Code** — sets `claude-code.autoInstallIdeExtension: false` in VS
Code's settings so opening an integrated terminal there never silently
installs the Claude Code extension, and ends with `chezmoi init --apply`.
The `.chezmoiignore.tmpl` in the dotfiles source is what keeps
`claude-attach`/`claude-env`/`paste-image` off this machine — chezmoi itself
runs normally here.

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
| `client-env.ovpn` | Ubuntu server (inside gluetun) | The second, unrelated third-party environment |

They're for entirely different networks and neither is a fallback for the
other.

## 4. Verify

```sh
ssh <server-LAN-IP>   # over the OpenVPN-to-LAN path, once connected
```

Use the server's **LAN IP**, not `ubuntu-home`. That name is provided by
Tailscale MagicDNS, which this machine deliberately doesn't have — it will
not resolve here unless you've added a local DNS record for it on the
UDM SE. This machine also doesn't get the `claude-server` SSH alias (that
block is Tailscale-only, skipped by `dot_ssh/config.tmpl`).

If you want a shortcut, add your own `Host` entry pointing at the LAN IP in
a file chezmoi doesn't manage (e.g. `~/.ssh/config.d/`), or add a local DNS
entry on the UDM SE so `ubuntu-home` resolves over the VPN.
