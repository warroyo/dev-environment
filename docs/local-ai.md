# Local AI on the server: LiteLLM and Hermes

The server runs the agent side of the local-model stack. The EVO-X2 only
serves models ([inference-host.md](inference-host.md)); everything that calls
them lives here.

```
ubuntu-home                                              EVO-X2
┌─────────────────────────────────────────────┐          ┌────────────────────┐
│ Claude Code ──herdr──▶ Hermes               │          │ llama-swap :8080   │
│   lab profile:        commands on the host  │          │  qwen3.8-flash-next│
│                       (labs, as Claude)     │          │  qwen3.8-27b       │
│   restricted profile: commands in docker    │          │  qwen3.6-35b-a3b   │
│                       hermes-sandbox (web)  │ tailnet  │                    │
│ Hermes / scripts ──▶ LiteLLM 127.0.0.1:4000 ├─────────▶│                    │
│                       └─ Postgres :5433     │          └────────────────────┘
└─────────────────────────────────────────────┘
```

Claude Code itself does not go through LiteLLM; it talks to Anthropic
directly. No cloud model is in LiteLLM at all, so a request meant for the local
model cannot fall back to the cloud.

## Install

Part of `provision/server-bootstrap.sh`. To apply just this part:

```sh
./provision/local-ai-setup.sh
```

It needs docker, `jq`, `python3-yaml` (both come with the bootstrap) and
sudo for the systemd units.

## LiteLLM

`provision/lib/litellm.sh`. A docker compose stack in
`~/.local/share/litellm`, run by `litellm.service`:

- **litellm**, pinned by tag and digest, with host networking so it resolves
  `evo-x2` through MagicDNS. Listens on `127.0.0.1:4000` only.
- **postgres**, for virtual keys and spend logs, on `127.0.0.1:5433`.

Models come from `ansible/group_vars/inference.yml`, the file that also
drives llama-swap:

| LiteLLM model | Goes to |
|---|---|
| `local-qwen` | the first entry of `llama_swap_preload` (the working model) |
| `local-embed` | the embedding model (`alias: local-embed` in group_vars), for `/v1/embeddings` |
| every `llama_swap_models` name | that model on llama-swap |

Clients should ask for `local-qwen`. When the bake-off picks a model, change
`llama_swap_preload`, run the inference play and then `local-ai-setup.sh`, and
no client changes. `local-qwen` falls back to the llama.cpp model if its
engine fails; both are local.

Timeouts are 15 minutes and retries are off: asking for a model that is not
loaded makes llama-swap swap, and Flash-Next takes 1-2 minutes to load.

### Keys

| File | What |
|---|---|
| `~/.secrets/litellm/litellm.env` | master key, salt key, Postgres password. Generated once. Never change the salt key: it encrypts what is stored in the database |
| `~/.secrets/litellm/hermes-lab.key` | Hermes, `lab` profile |
| `~/.secrets/litellm/hermes-restricted.key` | Hermes, `restricted` profile |
| `~/.secrets/litellm/scripts.key` | for scripts and ad-hoc `curl` |
| `~/.secrets/litellm/content-curator.key` | the content curator ([warroyo/content-curator](https://github.com/warroyo/content-curator)) |

A client gets its own key so it can be cut off alone and its tokens counted
alone. Add one by putting its name in `LITELLM_CLIENTS` and re-running. The
admin UI is at `http://127.0.0.1:4000/ui` (log in with the master key; from
the laptop, `ssh -L 4000:127.0.0.1:4000 ubuntu-home`).

```sh
curl -s -H "Authorization: Bearer $(cat ~/.secrets/litellm/scripts.key)" \
  http://127.0.0.1:4000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"local-qwen","messages":[{"role":"user","content":"Say OK"}]}'
```

Both `/v1/chat/completions` and `/v1/responses` (with tool calls) work
through it; LiteLLM passes the Responses API straight to Gufo.

## Hermes

`provision/lib/hermes.sh`. Installed with the vendor's installer on the stable
channel, then configured key by key with `hermes config set`, so Hermes can
still migrate its own config between releases.

Always on for one thing only: the `lab` profile answers on Telegram once
it has a bot (see [On Telegram](#on-telegram)). No cron. Otherwise Hermes
runs when someone starts it, by hand or through Claude.

### Two profiles

Each Hermes profile is its own home (config, `.env`, memory, sessions), with
its own LiteLLM key.

| Profile | Start | Access |
|---|---|---|
| `lab` (the default, `~/.hermes`) | `hermes` | The same as Claude. Commands run on this host as Will: `~/.lab.env` and the client lab through `tun0`, agent SSH to the home lab over the tailnet. Same lines as Claude's permission rules: `approvals.deny` blocks `ssh *-admin*`, `ansible *`, `ansible-playbook` and `ansible/play`, so changes to lab machines still go through dev-environment code that Will runs |
| `restricted` | `hermes -p restricted` | Internet only. Commands run in a throwaway container on `hermes-sandbox`. Can write to `~/second-brain/inbox` (mounted at `/inbox`, files owned by Will) for notes to file later; no git, so nothing is pushed |

### Settings both share

| Setting | Value | Why |
|---|---|---|
| `model.*` | custom provider, `http://127.0.0.1:4000/v1`, `local-qwen`, Responses API, 131072 context | everything through LiteLLM |
| `model.key_env` | `LITELLM_API_KEY`, set in the profile's `.env` to that profile's LiteLLM key | a custom endpoint ignores `OPENAI_API_KEY` and would send `no-key-required` |
| `auth.adopt_external_logins` | `false` | the default lets Hermes borrow Claude Code's and Codex's logins. Their refresh tokens are single-use, so sharing logs the other out, and it hands Hermes a cloud model |
| `approvals.mode` | `manual` | every dangerous command is asked. Move to `smart` once trusted |
| `memory.write_approval`, `skills.write_approval` | `true` | memory on; memory and skill writes are shown and approved first |
| `telemetry.shared_metrics.*` | `false` | |

### On Telegram

The phone's direct line to Hermes: a chat with the `lab` profile on a bot of
its own, always on. Decided 2026-10-26, reversing "no gateway"; the
`restricted` profile was the safer choice and was turned down, because the
point is reaching the labs from the phone.

```sh
./provision/hermes-telegram-setup.sh   # after @BotFather → /newbot
```

It writes `~/.secrets/hermes-telegram` (`HERMES_TELEGRAM_*`, so the shells
that source `~/.secrets/*` keep the Claude bot's `TELEGRAM_BOT_TOKEN`), then
`configure_hermes` copies the token and allow-list into `~/.hermes/.env`,
sets `platforms.telegram.enabled=true` on `lab` only, and installs the
gateway as a systemd user service (`hermes gateway install`, Hermes owns the
unit) with lingering on, so it starts at boot.

What a Telegram session can do, and what stops a stranger:

- The allow-list (`TELEGRAM_ALLOWED_USERS`, Will's user id) is the whole gate.
  `unauthorized_dm_behavior: ignore` means strangers get no reply, not
  Hermes' default pairing code; the same rule as `claude-telegram-bot`.
- Approvals come to the chat as buttons, but `approvals.mode=manual` only
  asks for commands Hermes flags as dangerous. Reading `~/.lab.env` is not
  one, so whoever holds the Telegram session can read the lab credentials.
  A lost phone means revoking the bot's token (@BotFather → /revoke).
- Never the Claude bot's token: Telegram allows one `getUpdates` consumer per
  token. The setup script refuses it.

The service is also the profile's shared gateway, so `lab` sessions started
in herdr panes run their turns in it too, rather than in one the CLI starts
and stops on its own.

Off again: delete `~/.secrets/hermes-telegram`, run
`./provision/local-ai-setup.sh`, then `hermes gateway uninstall`.

### Skills and standing rules

A session nobody briefed (Telegram, a pane started by hand) needs to know the
lab without Claude handing it context, so the `lab` profile gets two things:

- **Skills**: `homelab`, `second-brain` and `lab-creds`, linked from
  `~/.claude/skills` into `~/.local/share/hermes-skills`, which is set as
  `skills.external_dirs`. The rest of Claude's skills are about Claude's own
  workflow or about coding, so they are left out. Edit the list in
  `HERMES_SHARED_SKILLS` (`provision/lib/hermes.sh`).
- **Rules**: a managed block at the end of `~/.hermes/SOUL.md`, the one
  context file Hermes loads in every session wherever it starts: the homelab
  skill first, `lab-creds` for logins, read-only on live machines, changes as
  code, the work laptop out of scope, the vault through `second-brain` only.
  Hermes' own persona text above the block is left alone.

The `restricted` profile gets neither: it cannot reach the labs or the vault
outside `inbox/`.

### The sandbox network

The `restricted` profile's command containers run on the `hermes-sandbox` Docker network (bridge
`br-hermes`). `hermes-sandbox-egress.service` puts iptables rules in place
that let it reach the internet and nothing else:

- no `tun0`: without a rule Docker's NAT would send `10.47.7.x` traffic down
  the client-lab VPN
- no `tailscale0`: this box is untagged, so a container NATed out of it would
  reach every lab machine, llama-swap included
- no private ranges (10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16),
  and nothing addressed to the host itself

Check it from inside:

```sh
docker run --rm --network hermes-sandbox curlimages/curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.com   # 200
docker run --rm --network hermes-sandbox curlimages/curl -s -m 5 http://evo-x2:8080/v1/models || echo blocked
```

## Delegating to Hermes

Will runs Hermes by hand in a herdr pane, from the laptop (`herdr --remote`)
or the phone. Claude also delegates to it to save tokens, using the `hermes`
skill (`dotfiles/dot_claude/skills/hermes`):

- high-input, low-output jobs: triaging logs and cluster state, summarizing
  many documents, reading a docs site for one answer
- `lab` for anything touching the labs (Hermes gathers the data itself),
  `restricted` for internet-only research
- Hermes writes a full result and a summary of at most 15 lines, and Claude
  reads the summary rather than the pane, which is where the saving comes from

Hermes never drives Claude. The home lab and the client lab are not
sensitive, so anything Claude may work on may be delegated. The work laptop
is outside this setup.

herdr reads most agents' state off the screen, but its Hermes rules no longer
match the Hermes TUI (herdrdev/herdr#5336), so on its own herdr shows a
Hermes pane as `idle` forever. The setup installs a small Hermes plugin,
`herdr-push-state`, that pushes the state from Hermes' own hooks instead:
`working` when a turn starts, `blocked` on an approval or question, `idle`
(shown as `done` if nobody is looking) when the turn ends. That is what
makes `herdr agent wait` usable.

Hermes runs every turn in one shared gateway process per profile, not in
the pane, so the plugin cannot use its own environment to find the pane.
`terminal.client_env_passthrough` makes each session carry `HERDR_ENV`,
`HERDR_PANE_ID` and `HERDR_SOCKET_PATH` from the pane that opened it
(herdrdev/herdr#5373 describes the same problem for herdr's own plugin).

Claude may start, prompt, wait on and read workers without asking. `herdr agent send-keys`, which answers
Hermes' approval prompts, always asks Will.

Each `lab` job lives in `~/hermes-work/<topic>/`: the brief, the result, the
summary and any scripts Hermes writes. Hermes runs Python from files there
rather than with `python3 -c` or a heredoc, because its approval check stops
on inline code but not on a script file. Claude closes the worker's pane once
it has read the summary. `hermes-work-prune.timer` deletes a job folder once
nothing in it has changed for 14 days (`HERMES_WORK_RETENTION_DAYS`), and
prunes Hermes' own `~/.hermes/cache/scratch` the same way. Preview with
`hermes-work-prune --dry-run`.

## Upgrading

- **LiteLLM**: change `LITELLM_IMAGE` in `lib/litellm.sh` to a new tag and
  its digest (`docker buildx imagetools inspect ghcr.io/berriai/litellm:<tag>`),
  then re-run. The database migrates on start.
- **Hermes**: `hermes update`, then re-run `local-ai-setup.sh` to put the
  settings back if a migration moved any.
