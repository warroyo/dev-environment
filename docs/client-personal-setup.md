# Personal MacBook Air setup (role: `personal`)

The full Claude Code client, reached over Tailscale. Gets both layers:
general terminal/editor defaults, and the Claude-specific
`claude-attach`/`claude-env` workflow.

## 1. Run the bootstrap script

```sh
git clone <this-repo-url> ~/dev-environment
cd ~/dev-environment
./provision/client-personal-bootstrap.sh
```

Installs Tailscale, Ghostty, Mosh, chezmoi, gh, Obsidian, and VS Code + the Remote-SSH
extension via Homebrew, and ends by applying the dotfiles
(`chezmoi init --apply`).

It also installs `herdr`, the multiplexer holding the persistent session (see
[server-setup.md](server-setup.md) for the server half). That one comes from a
pinned, checksum-verified release binary rather than Homebrew — there's no
official formula, and the pin matters: client and server negotiate a protocol
version, so both ends have to agree. The version lives in
`provision/lib/herdr.sh` and nowhere else.

It also writes `/etc/resolver/set.lab` so the lab's internal zone — and only
that zone — resolves through the server's dnsmasq, pointed at the server's
**tailnet** address first and its **LAN** address (`10.10.2.116`) second, so
the zone still resolves at home with Tailscale off. That needs `sudo`, so the
run will prompt. The server
advertises `10.47.0.0/16` as a subnet route, so the lab works from any network
the tailnet reaches, not just the home LAN. Delete the file if you'd rather not
have it. See [`docs/client-work-setup.md`](client-work-setup.md) §6.

**This step is skipped on a first run**, because it resolves the server's
address with `tailscale ip -4` and step 2 below hasn't happened yet. The script
says so and continues. Re-run it after `tailscale up`:

```sh
./provision/client-personal-bootstrap.sh
```

Re-running is also how a changed tailnet address gets picked up — nothing is
hardcoded, so the file is only as current as the last run.

To check it, with `client-vpn up` run on the server:

```sh
tailscale status | grep ubuntu-home             # the peer is up
netstat -rn | grep 10.47                        # subnet route present, via utun
dscacheutil -q host -a name auto.gpu.set.lab    # a name resolves
```

`dig` and `nslookup` **ignore** `/etc/resolver` entirely — they query a server
directly and will report failure while Chrome, `curl` and `ping` all work. The
equivalent by hand is `dig -p 5300 @<server-tailnet-ip> auto.gpu.set.lab`.

### If you already had apps installed

The script skips anything already present — VS Code dragged into
`/Applications`, an existing Tailscale app, whatever. It does **not** try to
install a second copy, and it won't abort when it finds one. If you'd rather
Homebrew manage an app you installed by hand:

```sh
brew install --cask --adopt visual-studio-code
```

**Tailscale specifically:** the GUI app and the `tailscale` Homebrew *formula*
each ship their own daemon, and running both means two `tailscaled` instances
competing for the same tunnel. The script installs the formula only when no
Tailscale app exists. If you ended up with both, remove the formula and keep
the app:

```sh
sudo brew services stop tailscale
brew uninstall tailscale
```

The app bundles the CLI but doesn't put it on `PATH`, so the shell config
aliases `tailscale` to it — that's why `tailscale status` works below.

## 2. Manual: sign into Tailscale

```sh
tailscale up
```

Interactive — follow the printed auth URL, or use the Tailscale menu-bar
app if you prefer. Confirm the server (`ubuntu-home`) is visible:

```sh
tailscale status | grep ubuntu-home
```

## 2b. Set your login name for the server

The `Host claude-server` block in the managed SSH config deliberately carries
no `User` — that's identifying, so it stays out of the repo. Put it in
`~/.ssh/config.local`, which is included first and therefore wins:

```sshconfig
Host claude-server
  User your-login-name-on-the-server
```

The bootstrap creates that file with a comment to this effect. Skip it only if
your Mac username already matches your server username.

## 3. Manual: add the server to VS Code Remote-SSH

VS Code Remote-SSH reads `~/.ssh/config`, which chezmoi already populated
with a `Host claude-server` entry pointing at the server's Tailscale
hostname (`dotfiles/private_dot_ssh/private_config.tmpl`). Open the command palette →
"Remote-SSH: Connect to Host..." → `claude-server` should already be listed
with no further config.

## 3b. Manual: the second-brain vault in Obsidian

The bootstrap installs Obsidian and `gh`, and clones the private
`warroyo/second-brain` repo to `~/second-brain`. The clone needs GitHub
credentials the script does not set up, so on a first run it prints a warning
and carries on. Log in, wire git to `gh`, and re-run:

```sh
gh auth login                 # HTTPS, authenticate in the browser
gh auth setup-git             # git pushes from Obsidian use the gh token
./provision/client-personal-bootstrap.sh
```

Then, once:

1. Obsidian → **Open folder as vault** → `~/second-brain`.
2. Settings → Community plugins → turn on community plugins → install and
   enable **Git** (`obsidian-git`).
3. In the Git plugin settings, set **Auto commit-and-sync interval** (10
   minutes is fine), turn on **Pull on startup**, and set **Sync method** to
   **Rebase**.

Rebase matters because the vault has two writers. The server's
`dev-log-entry` commits a session entry to `entries/` and pushes; the Mac
pushes whatever you wrote by hand. Both rebase onto `origin` before pushing,
so neither needs the other to be idle. Per-machine UI state
(`.obsidian/workspace*.json`) is in the vault's `.gitignore`, so the two never
conflict over which pane was open.

`entries/` and `pitches/` belong to the Claude Code commands on the server —
read them in Obsidian, link to them, but write your own notes in `topics/`,
`notes/` and `inbox/`. The layout is in `~/second-brain/README.md`.

## 4. Try it

```sh
claude-attach
```

Runs a herdr client locally and bridges it to the server's session over ssh,
landing you in the `claude-main` workspace with `claude` already running via
`herdr-server.service`.

Detach with **`Ctrl-b q`** — the prefix matches tmux, the detach key does not.
`claude-attach --mosh` runs the client on the server instead (worth it on a
roaming link, at the cost of clipboard image paste); `claude-attach --tmux` is
the escape hatch for when the herdr server is what's broken. See
[herdr-cheatsheet.md](herdr-cheatsheet.md).

## Primary surface

Ghostty + herdr (via `claude-attach`) is the primary surface for actually
working with Claude Code. VS Code Remote-SSH is for diffs and file
browsing — open it on demand when you want a GUI diff view or to browse the
tree, not left running as the main interface.

`claude-vscode` (alias `cv`) does both in one command: opens VS Code
Remote-SSH to the server, then attaches this terminal to the same
`claude-main` session `claude-attach` would. See
[`docs/terminal-and-editor-defaults.md`](terminal-and-editor-defaults.md#claude-vscode).
