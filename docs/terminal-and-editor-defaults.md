# Terminal and editor defaults

This is the **general layer** — it applies to all three machines: the
Ubuntu server, the personal MacBook Air, and the work MacBook Pro. Nothing
in this document is Claude-specific.

## Ghostty ([`dotfiles/dot_config/ghostty/config`](../dotfiles/dot_config/ghostty/config))

- **`term = xterm-256color`** — Ghostty's native terminfo (`xterm-ghostty`)
  usually isn't installed on remote Linux hosts. Without this, tmux over SSH
  can't find a matching terminfo entry and colors/keybindings break in
  confusing ways. Rather than patching terminfo on every remote host you
  ever SSH into, Ghostty just reports a terminal type every host already
  understands.
- **`macos-option-as-alt = true`** — lets Option act as Alt/Meta, needed for
  readline and vim word-jump bindings (Alt-b, Alt-f, etc.).
- **`copy-on-select = true`** — selecting text copies it immediately, no
  separate Cmd-C needed.

## tmux ([`dotfiles/dot_tmux.conf`](../dotfiles/dot_tmux.conf))

Full keybinding reference: [`docs/tmux-cheatsheet.md`](tmux-cheatsheet.md).

Two SSH-specific fixes baked into the config:

1. **Colors going muted inside tmux.** `TERM` becomes `tmux-256color`
   inside a tmux session, and SSH doesn't forward `COLORTERM`, so programs
   inside tmux often think they're limited to 256 colors even though the
   terminal supports true color. `terminal-overrides` asserts RGB support
   and forces `COLORTERM=truecolor` for anything running inside tmux.
2. **Shift-Enter submitting instead of inserting a newline.** tmux collapses
   modified key sequences by default. `extended-keys on` passes the real key
   sequence through instead of the collapsed form.

Session persistence is handled by the well-established
[`tmux-resurrect`](https://github.com/tmux-plugins/tmux-resurrect) +
[`tmux-continuum`](https://github.com/tmux-plugins/tmux-continuum) plugins
(managed by [tpm](https://github.com/tmux-plugins/tpm)) rather than a
custom save/restore script — auto-save every 5 minutes, auto-restore on
tmux server start.

## VS Code ([`dotfiles/dot_config/vscode/settings.json`](../dotfiles/dot_config/vscode/settings.json))

General editor defaults — font, formatting, theme, trailing-whitespace
trimming. Nothing Claude-related lives in this file; on the work laptop it
applies exactly as it does everywhere else.

Because VS Code doesn't read settings from `~/.config` on macOS, a chezmoi
`run_onchange` script
([`dotfiles/run_onchange_after_install-vscode-settings.sh.tmpl`](../dotfiles/run_onchange_after_install-vscode-settings.sh.tmpl))
copies this file over the real, OS-specific settings file on `chezmoi apply`.

It copies rather than symlinks on purpose. A symlink points VS Code's own
writes — theme changes, font tweaks, extensions recording that you dismissed
them — at chezmoi's target file, so the next `chezmoi apply` stops with
`.config/vscode/settings.json has changed since chezmoi last wrote it?` and
waits for an answer that a provisioning script can't give. Copying keeps the
two files separate: VS Code writes only its own, and chezmoi's can never drift.

The trade is that the repo wins on a schedule rather than continuously. The
script embeds a hash of `settings.json`, so it re-runs and re-copies whenever
the managed settings change — an edit here lands on the next apply, overwriting
whatever VS Code wrote in between. A setting changed only in VS Code's UI
survives until then. For the one setting that matters on the work laptop
(`claude-code.autoInstallIdeExtension`), the backstop is the check in
`provision/client-work-bootstrap.sh`, which fails the run if the Claude Code
extension is actually installed.

## Common CLI tools

Installed by every `provision/*-bootstrap.sh` script (via apt on the server,
Homebrew on both Macs):

| Tool | Replaces | Why |
|---|---|---|
| [`ripgrep`](https://github.com/BurntSushi/ripgrep) (`rg`) | `grep` | Much faster, respects `.gitignore` by default |
| [`fd`](https://github.com/sharkdp/fd) | `find` | Simpler syntax, sane defaults, respects `.gitignore` |
| [`bat`](https://github.com/sharkdp/bat) | `cat` | Syntax highlighting, git-diff markers in the gutter |
| [`eza`](https://github.com/eza-community/eza) | `ls` | Colorized, git-aware, tree view |
| [`fzf`](https://github.com/junegunn/fzf) | — | Fuzzy history/file search, wired into shell keybindings |

`50_aliases.sh` aliases `ls`→`eza` and `cat`→`bat` unconditionally on all
three machines.

`find` and `grep` are deliberately **not** aliased to `fd`/`rg`. Their flag
syntax is incompatible (`find . -name x` and `grep -r` are both errors under
the replacements), so aliasing them breaks muscle memory and any
copy-pasted command in ways that are annoying to debug. Use `fd` and `rg` by
name.

Shell config also sets up zsh history (50k entries, shared live across
concurrent shells, timestamped) and case-insensitive completion.

## Shell layout: startup tiers and fragments

Shell config is split by *when zsh reads it*, not by topic:

| File | Read by | Contains |
|---|---|---|
| `~/.zshenv` | **Every** zsh — scripts, `zsh -c`, cron, `ssh host <cmd>` | PATH, `EDITOR`. Must be fast and silent. |
| `~/.zshrc` | Interactive shells | Sources the fragments below, then `~/.zsh.local` |
| `~/.config/shell/source/NN_*.sh` | Via `.zshrc` | One concern per file, loaded in numeric order |

**Why `.zshenv` exists at all:** non-interactive shells never read `.zshrc`. With
PATH set only there, `ssh claude-server 'claude --version'` fails with *command
not found*, and so does anything else invoked remotely or from a script.

Fragment contract — pick deliberately when adding one:

- **Guarded** with `[[ -o interactive ]] || return` → interactive-only UX
  (aliases, prompt, history, completion).
- **Unguarded** → environment; must be fast, silent, and never touch a tty.

Numeric prefixes control order: `10-19` terminal/locale basics, `40-49` PATH,
`50-59` environment and interactive UX, `60-69` machine-specific (ssh agent,
browser), `70-79` role-specific.

We deliberately do **not** have `~/.zprofile` source `~/.zshrc`. That's a common
pattern for getting environment into `zsh -lc`, but it makes interactive *login*
shells source `.zshrc` twice — duplicating PATH entries and registering prompt
hooks twice. Putting the whole environment tier in `.zshenv` gets the same
benefit without that hazard.

## Local overrides — what stays out of the repo

Anything machine-specific or identifying lives outside git. The repo holds no
hostnames, no email address, and no credentials.

| Path | Holds |
|---|---|
| `~/.config/chezmoi/chezmoi.toml` | This machine's **role** (written by the bootstrap script) |
| `~/.zsh.local` | Shell overrides; sourced last so it wins |
| `~/.gitconfig.local` | Git identity (`user.name` / `user.email`) |
| `~/.ssh/config.local` | Usernames, one-off hosts; included *first* so it wins |
| `~/.secrets/*` | Tokens and credentials, sourced by `55_secrets.sh` |

The bootstrap scripts seed `~/.gitconfig.local` from whatever git identity the
machine already has, so applying these dotfiles never silently changes who your
commits are attributed to.

Consider a dedicated email alias rather than your primary address — it keeps
your real mailbox out of every public commit while staying attributable.

## Roles instead of hostnames

Which layers a machine gets is decided by an explicit **role**, not by matching
its hostname:

| Role | Gets |
|---|---|
| `server` | General layer + Claude Code layer + headless-browser remap |
| `personal` | General layer + Claude Code layer + `paste-image` |
| `work` | General layer only |
| `restricted` | **Default.** Same as `work`. |

The default is the most restrictive value, so the scheme **fails closed**: a
machine that never declared a role gets the general layer only. Hostname
matching failed *open* — an unmatched hostname received the full Claude Code
layer, exactly backwards for a rule whose job is keeping Claude Code off one
machine. It was also fragile: chezmoi strips the domain from
`.chezmoi.hostname` and macOS reports mixed case, which silently broke matching
twice during development.

## `vscode-here`

Opens the current directory in VS Code. Behaviour depends on where you run it:

- **Locally** (no `$SSH_CONNECTION`): runs `code .`. A Remote-SSH URI pointing
  at your own hostname is meaningless — you don't Remote-SSH into yourself.
- **Over SSH**: prints a `vscode://vscode-remote/ssh-remote+<host><path>` link
  that opens VS Code *on your local machine*, attached to the remote directory.

Two things it has to get right, both of which are easy to miss:

**The host must be a name the client knows.** The URI is resolved by the
*client's* `~/.ssh/config`, not the server's. Prefer an ssh alias
(`claude-server`) over the server's own hostname (`ubuntu-home`): the alias
carries `User`, whereas a bare hostname makes VS Code connect as whatever local
username the client happens to have — usually the wrong one. Set it per machine:

```sh
echo 'export VSCODE_HERE_HOST=claude-server' >> ~/.zsh.local
```

**The click may not work, and that's not a bug in the escape sequence.**
Terminals choose which URI schemes they linkify, and many handle only
`http(s)`/`mailto`. A `vscode://` link can render as plain text no matter how
correct the OSC8 sequence is. So the command also prints the raw URI and a
copy-pasteable `code --remote ...` line — use those if clicking does nothing.

## `claude-vscode`

The reverse direction from `vscode-here`: run it **on a client** (Ghostty,
not SSH'd into anything) and it opens VS Code Remote-SSH on
`$CLAUDE_SERVER_HOST` directly, then attaches the current terminal to the
`claude-main` tmux session — one command instead of opening VS Code by hand
and separately running `claude-attach`. Aliased to `cv`.

```sh
claude-vscode              # or: cv
claude-vscode ~/some/dir   # open VS Code to a specific remote folder
```

The path, if given, is resolved **on the server**, so it needs to be an
absolute remote path — `~` here would expand to the client's home directory,
not the server's, since VS Code's CLI runs locally.

If no path is given, `claude-vscode` asks the server for its own `$HOME` over
`ssh` first and opens `$HOME/workspace`. A folder is required for the remote
connection to actually happen — `code --remote ssh-remote+host` with no path
can silently open a disconnected local window instead of erroring.

**The VS Code window and the tmux session are independent connections, not a
paired one.** Claude Code's live IDE integration (inline diffs, selection
context) only pairs with a VS Code window when `claude` is launched from
*that window's own* integrated terminal. `claude-main` was started by
`claude-tmux.service`, not from inside VS Code, so the window this opens is a
manual file/diff browser — same as opening it via `vscode-here` yourself, just
without needing to already be SSH'd in first.

## Prompt and shell plugins

The bootstrap scripts set zsh as the login shell. zsh's *built-in* default
prompt is just `%m%#` — bare hostname and a `%`, no colours, no working
directory, no git info — which is a downgrade from Ubuntu's stock bash
prompt. So the prompt is configured explicitly:

| Piece | What it gives you |
|---|---|
| [`starship`](https://starship.rs) | cwd, git branch + dirty/untracked/ahead-behind status, exit code, and command duration for anything over 2s |
| `zsh-autosuggestions` | Ghost-text completion from history; accept with `→` |
| `zsh-syntax-highlighting` | Commands colour as you type — typos go red before you press enter |

`starship` is a single binary with a single config
([`dot_config/starship.toml`](../dotfiles/dot_config/starship.toml)), so the
prompt is identical on the server and both Macs. The hostname segment is
`ssh_only`, so it appears when you're on the server and stays out of the way
locally — useful when the whole point of the setup is working on a machine
that isn't the one in front of you.

Load order in `.zshrc` matters: `zsh-syntax-highlighting` must be sourced
**last**, or it won't wrap the widgets the other plugins install. Package
paths differ between Homebrew and apt, so the config probes both.

If `starship` is missing, `.zshrc` falls back to a simple coloured
`cwd ❯` prompt rather than dropping to the bare default.

## Fonts

The prompt uses Nerd Font glyphs (git branch, folder icons). The client
bootstrap scripts install `font-meslo-lg-nerd-font` and the Ghostty config
selects `MesloLGS Nerd Font`; VS Code's editor and integrated terminal use
the same family.

The font is installed on the **clients only** — the Mac's terminal renders
the glyphs, the headless server draws nothing.

If glyphs show as boxes, the family name may differ on your machine. List
what Ghostty actually sees and set the exact name in the config:

```sh
ghostty +list-fonts | grep -i meslo
```

## Applies everywhere

Every piece above — Ghostty, tmux, VS Code, the CLI tools — is part of the
general layer and is installed/applied identically on the work MacBook Pro
as on the server and the personal Air. See
[`docs/client-work-setup.md`](client-work-setup.md) for that machine's
setup steps.
