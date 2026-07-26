# dev-environment

Two-layer setup, one repo:

1. **General terminal/editor defaults** — shell, Ghostty, tmux, VS Code,
   common CLI tools. Applies to every machine, work laptop included.
2. **Remote Claude Code** — a persistent, always-on Claude Code host on an
   Ubuntu server, reachable from a personal MacBook Air over Tailscale and
   from a work MacBook Pro over OpenVPN (view/edit/SSH only — that laptop
   never runs Claude Code). Applies to every machine except the work laptop.

Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full
picture, then follow the setup doc for whichever machine you're on.

## Quickstart by machine

| Machine | Bootstrap | Setup doc |
|---|---|---|
| Ubuntu server | `provision/server-bootstrap.sh` | [`docs/server-setup.md`](docs/server-setup.md) |
| Personal MacBook Air | `provision/client-personal-bootstrap.sh` | [`docs/client-personal-setup.md`](docs/client-personal-setup.md) |
| Work MacBook Pro | `provision/client-work-bootstrap.sh` | [`docs/client-work-setup.md`](docs/client-work-setup.md) |

```sh
git clone <this-repo-url> ~/dev-environment
cd ~/dev-environment
./provision/<role>-bootstrap.sh
```

Every bootstrap script is idempotent — safe to re-run. Each ends by applying
the dotfiles with chezmoi, so a bootstrap run is the whole setup apart from
the interactive steps (Claude Code login, Tailscale auth, importing the
OpenVPN profile).

On the server, check the result at any time with:

```sh
./provision/verify-server.sh    # read-only; non-zero exit if anything failed
```

## Layout

```
docs/         architecture + per-machine setup docs
provision/    one idempotent bootstrap script per machine role
dotfiles/     single chezmoi source for all machines (layer 1 everywhere,
              layer 2 everywhere except the work laptop)
  .chezmoidata.yaml    hostnames + emails, referenced by every template
  .chezmoiignore.tmpl  the work-laptop exclusion (target paths!)
  dot_local/bin/       helper scripts -> ~/.local/bin (on PATH)
```

## Before you use this on the work laptop

`dotfiles/.chezmoidata.yaml` has one placeholder that must be filled in
before running chezmoi on the work MacBook Pro: `hostnames.workLaptop`. If
it doesn't match that machine's `hostname` exactly, `.chezmoiignore.tmpl`
won't match and the Claude-specific scripts **will be installed there**.

See [`docs/client-work-setup.md`](docs/client-work-setup.md#0-before-you-start-set-the-real-hostname).

Note that `.chezmoiignore` patterns match **target** paths (`.local/bin/claude-attach`),
not source paths (`dot_local/bin/executable_claude-attach`). Verify with
`chezmoi ignored` after any change to that file.

## Docs index

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — topology, rationale, the
  hard constraints this repo is built around, Definition of Done
- [`docs/terminal-and-editor-defaults.md`](docs/terminal-and-editor-defaults.md) — the general layer
- [`docs/tmux-cheatsheet.md`](docs/tmux-cheatsheet.md) — the handful of
  tmux bindings you actually need for this workflow
- [`docs/server-setup.md`](docs/server-setup.md)
- [`docs/client-personal-setup.md`](docs/client-personal-setup.md)
- [`docs/client-work-setup.md`](docs/client-work-setup.md)
