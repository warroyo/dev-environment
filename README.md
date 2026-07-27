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

## Nothing to fill in first

Which layers a machine gets is decided by an explicit **role** that the
bootstrap script writes to `~/.config/chezmoi/chezmoi.toml` — there are no
hostnames or placeholders to edit before running it.

| Role | Set by | Gets |
|---|---|---|
| `server` | `server-bootstrap.sh` | General + Claude Code layer |
| `personal` | `client-personal-bootstrap.sh` | General + Claude Code layer |
| `work` | `client-work-bootstrap.sh` | General layer only |
| `restricted` | default when unset | General layer only |

The default is the most restrictive value, so this **fails closed**: a machine
that never declared a role never receives the Claude Code layer.

## What is deliberately not in this repo

No hostnames, no email address, no credentials. Machine-specific and
identifying values live outside git — `~/.zsh.local`, `~/.gitconfig.local`,
`~/.ssh/config.local`, `~/.secrets/*`. The bootstrap scripts seed the git
identity from whatever the machine already has, so applying these dotfiles
never silently changes commit attribution. See
[`docs/terminal-and-editor-defaults.md`](docs/terminal-and-editor-defaults.md#local-overrides--what-stays-out-of-the-repo).

## Testing

```sh
docker build -t dev-env-test .
docker run --rm -e ROLE=work dev-env-test     # also: server, personal, restricted
```

Applies the dotfiles twice in a clean container to prove they're idempotent,
then asserts each role's exclusions actually took effect. Note
`.chezmoiignore` patterns match **target** paths (`.local/bin/claude-attach`),
not source paths — verify with `chezmoi ignored`.

## Docs index

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — topology, rationale, the
  hard constraints this repo is built around, Definition of Done
- [`docs/terminal-and-editor-defaults.md`](docs/terminal-and-editor-defaults.md) — the general layer
- [`docs/tmux-cheatsheet.md`](docs/tmux-cheatsheet.md) — the handful of
  tmux bindings you actually need for this workflow
- [`docs/server-setup.md`](docs/server-setup.md)
- [`docs/client-personal-setup.md`](docs/client-personal-setup.md)
- [`docs/client-work-setup.md`](docs/client-work-setup.md)
