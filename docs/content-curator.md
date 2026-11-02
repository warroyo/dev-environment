# Content curator

[content-curator](https://github.com/warroyo/content-curator) collects feeds and
podcasts, has `local-qwen` score them overnight, and publishes the day's picks
to a Raindrop.io collection with a reason on each. This repo installs it on the
server; the application, its tests and its image live in the curator repo. Once
a week Hermes searches the web for new sources and suggests them to the curator,
which tries the good ones (see [Source suggestions](#source-suggestions)).

```
 vault (Obsidian)                 server (ubuntu-home)                                   Raindrop.io
 notes/content-curator-sources.md ──┐
 notes/content-curator-interests.md ┴▶ render-config ─▶ ~/.local/share/content-curator/config/*.yaml
                                        (01:20, after a                    │ read-only
                                         ff-only vault pull)               ▼
                                     content-curator container :8090 ── 01:30 run ─────────▶ "AI picks"
                                        │ local-qwen, local-embed                       ◀── "To curate"
                                        ▼
                                     LiteLLM :4000 ─▶ EVO-X2
```

## Install

```sh
./provision/content-curator-setup.sh
```

`server-bootstrap.sh` runs the same step after LiteLLM. It needs:

- LiteLLM installed (`local-ai-setup.sh`), which makes `~/.secrets/litellm/content-curator.key`.
- The vault cloned at `~/second-brain`, with the two config notes.
- `~/.secrets/raindrop/token`: a Raindrop.io test token, made by hand at
  `app.raindrop.io/settings/integrations` (create an app, copy "Test token").
  Without it the service runs but every publish fails.

It is idempotent: re-run it after bumping the image pin or changing a setting.

## What it installs

| Path or unit | What |
|---|---|
| `content-curator.service` | `docker compose up` of the curator, on boot. `restart: unless-stopped` covers crashes. |
| `content-curator-config.timer` | 01:20 daily: fast-forward the vault, then `render-config`. |
| `content-curator-suggest.timer` | Saturday 10:00: `suggest-sources`, Hermes' weekly source suggestions. `CURATOR_SUGGEST=false` turns it off. |
| `~/.local/share/content-curator/suggest-sources` | generated: the brief, the context, one `hermes -p restricted -z` run, the post to the curator |
| `~/.local/share/content-curator/suggestions/` | each week's suggestions, as Hermes wrote them |
| `~/.local/share/content-curator/compose.yaml` | generated; the image pinned by tag and digest |
| `~/.local/share/content-curator/config/app.yaml` | generated: schedule and publishing, from the variables at the top of `lib/content-curator.sh` |
| `~/.local/share/content-curator/config/{sources,interests}.yaml` | rendered from the vault notes |
| `~/.local/share/content-curator/data/` | SQLite database (scores, picks, what was published) and the nightly reports |
| `~/.secrets/content-curator/curator.env` | generated: the LiteLLM key and the Raindrop token |

## Config from the vault

The curator reads plain YAML and knows nothing about the vault. Sources and
interests are preferences, tuned often, so they are written as two notes,
readable and editable in Obsidian: a few paragraphs of explanation, and the
settings in fenced `yaml` blocks. `render-config` joins each note's `yaml`
blocks in order, loads the result with the pinned image's own config code, and
only then replaces the file in `config/`. A note that does not parse or
validate leaves the last good file in place, and `content-curator-config.service`
shows failed.

An edit reaches the curator:

- from the server: at the next 01:20 render, or now with
  `sudo systemctl start content-curator-config.service`;
- from a Mac: once it is pushed, at the next 01:20 render (the vault pull is
  fast-forward only; anything else is left for you).

No restart is needed: the curator reads its config at the start of every job.

Schedule and publishing settings are deployment, so they stay here, in
`lib/content-curator.sh`.

## Source suggestions

The curator checks feeds it is given through `POST /api/candidates` but does not
look for them. Hermes does, on Saturday, a day before the curator's Sunday
`discover` job checks what came in:

```
 suggest-sources (Sat 10:00)                  Hermes, restricted profile          curator
 ─ interests.yaml, GET /api/sources,  ──▶ inbox/curator-discovery-*.md ──▶ web search
   GET /api/candidates                                                        │
 ◀──────────── inbox/curator-candidates.yaml ◀────────────────────────────────┘
 ─ POST /api/candidates?by=hermes ─────────────────────────────────────────▶ pending
                                                       Sun 01:00 discover: check, judge, trial
```

The restricted profile can write only to the vault's `inbox/`, so the brief, the
context (the interest profile, every source the curator knows, earlier
suggestions and their verdicts) and Hermes' answer all pass through it, and
`suggest-sources` removes them when it is done. Hermes only suggests: the
curator fetches each feed, rejects dead, flooding and GitHub release feeds and
known sources, and has the chat model judge fit, so a bad suggestion costs a
line in the rejected list. Passing feeds run as trials; you keep one with a
`follow` tag on one of its picks in Raindrop, or drop any source with
`unfollow`. Followed sources live in the curator's database, not in the vault
note, which stays the hand-kept base list; `curl -s 127.0.0.1:8090/api/sources`
shows the full list.

Run it now, or see what it did:

```sh
sudo systemctl start content-curator-suggest.service
journalctl -u content-curator-suggest -n 30 --no-pager
curl -s 127.0.0.1:8090/api/candidates | jq '.[] | {submitted_url, status, reason}'
```

## Upgrading

The curator repo's `image` workflow tests every push to main and publishes
`ghcr.io/warroyo/content-curator:sha-<commit>`; the run summary prints the
tag and digest. Put them in `CURATOR_IMAGE` in `lib/content-curator.sh` and
re-run the setup script. Older `sha-` images are removed afterwards.

## Checking on it

```sh
curl -s http://127.0.0.1:8090/api/status | jq '.last_runs[:3]'
curl -s http://127.0.0.1:8090/api/reports/latest | less
curl -s http://127.0.0.1:8090/api/sources | jq 'group_by(.status) | map({(.[0].status): length}) | add'
systemctl status content-curator content-curator-config --no-pager
journalctl -u content-curator-config -n 20 --no-pager
```

Metrics go to the **Content curator** row of Lab overview (docs/lab-metrics.md).

## Moving from the hand-started container

Before this, the curator ran from a working copy (`~/workspace/content-curator`,
`make up`). The first install removes that container and copies its `data/`
across, once. The working copy, its `data/` and its `.env` (which holds the
Raindrop token) stay; delete them when the new install has run a night.
