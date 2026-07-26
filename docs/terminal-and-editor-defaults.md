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

## Applies everywhere

Every piece above — Ghostty, tmux, VS Code, the CLI tools — is part of the
general layer and is installed/applied identically on the work MacBook Pro
as on the server and the personal Air. See
[`docs/client-work-setup.md`](client-work-setup.md) for that machine's
setup steps.
