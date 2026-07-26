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
([`dotfiles/run_onchange_after_link-vscode-settings.sh.tmpl`](../dotfiles/run_onchange_after_link-vscode-settings.sh.tmpl))
symlinks the real, OS-specific settings file to this one on `chezmoi apply`.

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

`dot_zshrc.tmpl` aliases `ls`→`eza` and `cat`→`bat` unconditionally on all
three machines.

`find` and `grep` are deliberately **not** aliased to `fd`/`rg`. Their flag
syntax is incompatible (`find . -name x` and `grep -r` are both errors under
the replacements), so aliasing them breaks muscle memory and any
copy-pasted command in ways that are annoying to debug. Use `fd` and `rg` by
name.

Shell config also sets up zsh history (50k entries, shared live across
concurrent shells, timestamped) and case-insensitive completion.

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
