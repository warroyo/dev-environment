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

Installs Tailscale, Ghostty, Mosh, chezmoi, and VS Code + the Remote-SSH
extension via Homebrew, and ends by applying the dotfiles
(`chezmoi init --apply`).

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

`claude-vscode` (alias `cv`) does both in one command: opens VS Code
Remote-SSH to the server, then attaches this terminal to the same
`claude-main` session `claude-attach` would. See
[`docs/terminal-and-editor-defaults.md`](terminal-and-editor-defaults.md#claude-vscode).
