# herdr cheatsheet

The bindings and commands you actually need for this workflow. herdr owns the
persistent Claude Code session on the server; see
[`ARCHITECTURE.md`](ARCHITECTURE.md#why-one-always-on-host) for why it replaced
tmux, and [`tmux-cheatsheet.md`](tmux-cheatsheet.md) for tmux, which is still
installed for ad-hoc use.

## Getting in

| Command | What it does |
|---|---|
| `claude-attach` | herdr client **here**, bridged to the server over ssh. The default. |
| `claude-attach --mosh` | herdr client **on the server**, over mosh. Survives a roaming or flaky link. |
| `claude-attach --tmux` | Escape hatch: a plain tmux session over ssh, touching no part of herdr. |
| `claude-env` | The second VPN environment, in its own named herdr session. |

The default renders the TUI locally, so local keybindings apply and a clipboard
image paste is forwarded into the remote pane. `--mosh` ships a rendered screen
instead and gives that up, in exchange for mosh's roaming and predictive echo.

Neither runs inside tmux — both refuse rather than stack two multiplexers.

## Keys

Prefix is `Ctrl-b`, same as tmux. **Detach is `Ctrl-b q`, not `Ctrl-b d`** —
the one binding that will catch you out coming from tmux.

| Key | Action |
|---|---|
| `Ctrl-b q` | Detach (leaves everything running on the server) |
| `Ctrl-b ?` | Keybinding help, `/` filters it live |
| `Ctrl-b b` | Toggle the sidebar — the agent-state panel |
| `Ctrl-b Shift-N` | New workspace |
| `Ctrl-b c` | New tab |
| `Ctrl-b "` / `Ctrl-b %` | Split the pane |
| `Ctrl-b` + arrows | Move between panes |
| `Ctrl-b [` | Copy mode |

The sidebar is the thing tmux had no answer for: every workspace with its
agent's live state — `idle`, `working`, `blocked`, `done`. It only earns its
place with more than one agent running, which is the normal state once the
Telegram bot has opened a few.

## Agent states

| State | Meaning |
|---|---|
| `idle` | Ready for input, and its tab has been seen in a focused UI |
| `working` | Busy |
| `blocked` | herdr recognised an approval or question prompt — it wants you |
| `done` | Finished background work you have not looked at yet |
| `unknown` | An agent is present but herdr cannot classify it confidently |

`done` and `idle` are the same underlying state; the difference is whether
you've looked. `unknown` does **not** mean finished.

## From the shell

Everything the TUI does is also a command, which is how `claude-open`,
`herdr-main-workspace` and `verify-server.sh` drive it.

```bash
herdr workspace list                  # what exists
herdr agent list                      # what is running, and its state
herdr pane list                       # panes with their cwd
herdr pane read <pane-id>             # what a pane is showing
herdr agent prompt <name> "..."       # send a prompt
herdr agent wait  <name> --until idle # block until it finishes
herdr workspace close <workspace-id>  # end one
```

Most commands return JSON — read ids and state out of the response rather than
predicting them. `herdr agent wait` is the one with no tmux equivalent at all:
under tmux the same thing meant polling `capture-pane` against a regex.

## Server side

```bash
systemctl status herdr-server          # the unit that owns the session
herdr-main-workspace                   # recreate claude-main if it is missing
journalctl -u herdr-server -n 50       # why it will not start
./provision/verify-server.sh           # checks the session end to end
```

A server restart brings the layout back and relaunches agents within a few
seconds, but as **fresh** conversations unless the Claude Code integration is
installed (`provision/herdr-setup.sh --with-claude-integration`).

To hand the session back to tmux entirely:

```bash
./provision/herdr-setup.sh --uninstall
```
