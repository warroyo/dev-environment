# tmux cheatsheet

Practical, not comprehensive — just what you actually need for the
`claude-attach`/`claude-env` workflow. Reflects the real bindings in
[`dotfiles/dot_tmux.conf`](../dotfiles/dot_tmux.conf), not generic tmux
defaults.

## First: how the prefix works

Everything below starts with the **prefix**, `Ctrl-b` (tmux's default,
unchanged here). It is a **sequence, not a chord**:

```
press Ctrl-b   →   RELEASE it   →   press the next key
```

**Pressing `Ctrl-b` on its own does nothing visible.** No indicator, no
feedback — tmux is silently waiting for the second key. That is not a broken
config; it's how the prefix works. If you press `Ctrl-b` and nothing happens,
you haven't pressed the second key yet.

If you get stuck mid-prefix, `Esc` or `Ctrl-c` cancels it.

## The things you'll actually use

**Detach** — leave everything running on the server and come back later. This
is the whole point of the setup:

```
prefix, then d
```

Closing the SSH connection or the terminal window without detaching also works;
tmux keeps running on the server either way.

**Scroll back through output:**

- Easiest: scroll with the mouse/trackpad. `mouse on` (custom) makes the
  scrollwheel enter scrollback automatically.
- Keyboard: `prefix, then [` enters copy mode, `↑`/`↓`/`PgUp`/`PgDn` to move,
  `q` to exit.

## Running a shell next to Claude

Claude Code owns the whole screen, so you can't type shell commands into its
window. To run something alongside it — `vscode-here`, `git status`, a log
tail — you need a second **window** or **pane**.

**Windows** (separate full screens, easiest):

| Binding | Does |
|---|---|
| `prefix, then c` | Create a new window (a shell) |
| `prefix, then 0` | Jump to window 0 — where `claude` runs |
| `prefix, then 1` | Jump to window 1 |
| `prefix, then n` / `p` | Next / previous window |
| `prefix, then w` | Pick a window from a list |
| `prefix, then &` | Close the current window (asks to confirm) |

The window list is the bar along the bottom of the screen; the active one is
highlighted.

**Panes** (side by side, when you want to see both at once) — these two are
custom to this repo, and both open in the current pane's directory:

| Binding | Does |
|---|---|
| `prefix, then \|` | Split vertically (side by side) |
| `prefix, then -` | Split horizontally (stacked) |
| `prefix, then arrow key` | Move between panes |
| `prefix, then z` | Zoom the current pane full-screen; again to un-zoom |
| `prefix, then x` | Close the current pane (asks to confirm) |

`prefix z` is worth remembering: split panes make Claude's UI cramped, so zoom
it back to full width while you're working in it.

## Other custom bindings

| Binding | Does |
|---|---|
| `prefix, then r` | Reload `~/.tmux.conf` and show a confirmation |

## Session persistence

| Binding | Does |
|---|---|
| `prefix, then Ctrl-s` | Save session state now (`tmux-resurrect`) — rarely needed, `tmux-continuum` auto-saves every 5 minutes |
| `prefix, then Ctrl-r` | Restore saved state — happens automatically after a server reboot |

## Troubleshooting

**"`Ctrl-b` does nothing."** It's a prefix — press and release it, *then* press
the command key. See the top of this page.

**"Claude vanished."** Check the window list (`prefix w`) — it's probably in
another window, not gone. `claude` normally runs in window 0.

**"tmux says no sessions."** The persistent session is started by
`claude-tmux.service`. Check it with `systemctl status claude-tmux`, and see
[`docs/server-setup.md`](server-setup.md).
