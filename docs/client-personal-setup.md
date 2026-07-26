# Personal MacBook Air setup (`wills-MacBook-Air.local`)

The full Claude Code client, reached over Tailscale. Gets both layers:
general terminal/editor defaults, and the Claude-specific
`claude-attach`/`claude-env` workflow.

## 1. Run the bootstrap script

```sh
git clone <this-repo-url> ~/dev-environment
cd ~/dev-environment
./provision/client-personal-bootstrap.sh
```

Installs Tailscale, Ghostty, Mosh, chezmoi, and VS Code + the Remote-SSH
extension via Homebrew, and ends by applying the dotfiles
(`chezmoi init --apply`).

## 2. Manual: sign into Tailscale

```sh
tailscale up
```

Interactive — follow the printed auth URL, or use the Tailscale menu-bar
app if you prefer. Confirm the server (`ubuntu-home`) is visible:

```sh
tailscale status | grep ubuntu-home
```

## 3. Manual: add the server to VS Code Remote-SSH

VS Code Remote-SSH reads `~/.ssh/config`, which chezmoi already populated
with a `Host claude-server` entry pointing at the server's Tailscale
hostname (`dotfiles/dot_ssh/config.tmpl`). Open the command palette →
"Remote-SSH: Connect to Host..." → `claude-server` should already be listed
with no further config.

## 4. Try it

```sh
claude-attach
```

Should SSH to the server and attach to (or create) the `claude-main` tmux
session, with `claude` already running via `claude-tmux.service`.

## Primary surface

Ghostty + tmux (via `claude-attach`) is the primary surface for actually
working with Claude Code. VS Code Remote-SSH is for diffs and file
browsing — open it on demand when you want a GUI diff view or to browse the
tree, not left running as the main interface.
