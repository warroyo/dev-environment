# tmux cheatsheet

Practical, not comprehensive — just what you actually need for the
`claude-attach`/`claude-env` workflow (one persistent session on the
server). Reflects the actual bindings in
[`dotfiles/dot_tmux.conf`](../dotfiles/dot_tmux.conf), not generic tmux
defaults. Skips pane-splitting/window-juggling since that workflow doesn't
need it day-to-day.

The **prefix** is tmux's default, `Ctrl-b` — press it, release, then press
the next key. It's not changed in this config.

## The two things you'll actually use

**Detach** (leave the session running on the server, come back to it
later — this is the whole point of the setup):

```
prefix, then d
```

Closing the SSH connection or the terminal window without detaching first
also works fine — tmux keeps running on the server either way.

**Scroll back through output:**

- Easiest: just scroll with the mouse/trackpad. `mouse on` (custom, in this
  config) makes the scrollwheel enter scrollback automatically.
- Keyboard alternative: `prefix, then [` enters copy mode, `↑`/`↓`/`PgUp`/
  `PgDn` to move, `q` to exit back to the live pane.

## Custom, from this repo's `dot_tmux.conf`

| Binding | Does |
|---|---|
| `prefix, then r` | Reload `~/.tmux.conf` without restarting the session |
| `prefix, then \|` | Split the current pane vertically (side by side) |
| `prefix, then -` | Split the current pane horizontally (stacked) |

You likely won't need the split bindings for the single-session workflow —
they're there if you ever want a second pane (e.g. to `tail -f` a log next
to `claude`).

## Stock tmux, worth knowing

| Binding | Does |
|---|---|
| `prefix, then arrow key` | Move between panes, if you've split any |
| `prefix, then z` | Zoom the current pane to fill the window, `prefix z` again to un-zoom |
| `prefix, then Ctrl-s` | Manually save session state (tmux-resurrect) — rarely needed, `tmux-continuum` auto-saves every 5 minutes |
| `prefix, then Ctrl-r` | Manually restore session state — used automatically on server reboot |

## Not covered here on purpose

Window creation/switching (`prefix c`, `prefix n`/`p`, `prefix 0-9`) and
anything about multiple windows — the `claude-attach`/`claude-env` workflow
is single-session, single-window. Ask if you end up wanting that.
