# Spanish tutor

[spanish-tutor](https://github.com/warroyo/spanish-tutor) is the memory behind a
12-week Mexican Spanish speaking plan. ChatGPT voice is the conversation
partner; the tutor knows the curriculum week, writes the prompt that starts each
session, takes the report that ends it, keeps the error log and turns errors
into FSRS review cards and typed drills, with `local-qwen` doing the
processing. This repo installs it on the server; the application, its tests and
its docs live in the tutor repo (its `PLAN.md` is the spec).

```
 iPhone / laptop                 server (ubuntu-home)                                  EVO-X2
 https://ubuntu-home.<tailnet>.ts.net:8443
        │  tailnet only
        ▼
 tailscale serve :8443 ─▶ spanish-tutor container 127.0.0.1:8096 ──▶ LiteLLM :4000 ─▶ local-qwen
                              │ data/tutor.db, recordings/
                              └ 04:10 backup timer ─▶ data/backups/
```

## Install

```sh
./provision/spanish-tutor-setup.sh
```

`server-bootstrap.sh` runs the same step after LiteLLM and the content curator.
It needs:

- LiteLLM installed (`local-ai-setup.sh`). The tutor is one of its clients
  (`LITELLM_CLIENTS` in `lib/litellm.sh`), so the key
  `~/.secrets/litellm/spanish-tutor.key` is made the same way as the curator's.
  If the file is missing, the setup script runs `install_litellm` to make it.
- GitHub access for the private repo: `gh auth login` as the user, once.
- Tailscale logged in, with HTTPS certificates enabled for the tailnet (admin
  console, DNS, HTTPS Certificates). The first `tailscale serve` fails without
  them and the script says so.

Run it as your own user, not root. It is idempotent: a re-run with nothing
changed rewrites nothing and restarts nothing. Agents never run it; Will does.

## What it installs

| Path or unit | What |
|---|---|
| `spanish-tutor.service` | `docker compose up` of the tutor, on boot. `restart: unless-stopped` covers crashes. |
| `spanish-tutor-backup.timer` | 04:10 daily (`SPANISH_TUTOR_BACKUP_AT`), runs `backup`. See [Backups and restore](#backups-and-restore). |
| `~/.local/share/spanish-tutor/src/` | clone of the private repo, detached at `SPANISH_TUTOR_REF`; the curriculum and prompt templates are read from it, read-only |
| `~/.local/share/spanish-tutor/compose.yaml` | generated; points at the local image `spanish-tutor:<12-char commit>` with `pull_policy: never` |
| `~/.local/share/spanish-tutor/data/` | `tutor.db` (SQLite), `recordings/`, `backups/` |
| `~/.local/share/spanish-tutor/backup` | generated: the backup script |
| `~/.secrets/spanish-tutor/tutor.env` | generated, mode 600: `LITELLM_BASE_URL`, `LITELLM_API_KEY`, `TUTOR_MODEL`, `TUTOR_HOST`, `TUTOR_PORT`, `TZ`, `TUTOR_START_DATE`, `TUTOR_WEEK_PLAN`, `TUTOR_NEW_CARDS_PER_DAY`, `TUTOR_DRILL_SCHEDULE`, `TUTOR_LOG_LEVEL` |
| `~/.secrets/litellm/spanish-tutor.key` | made by `lib/litellm.sh` |
| `tailscale serve` on `:8443` | `http://127.0.0.1:8096` at `https://ubuntu-home.<tailnet>.ts.net:8443/` |

The settings are variables at the top of `lib/spanish-tutor.sh`. Each can be
overridden for one run in the environment, for example
`SPANISH_TUTOR_START_DATE=2026-12-01 ./provision/spanish-tutor-setup.sh`.
The tutor settings are listed in the app repo's
`docs/reference/configuration.md`.

## Image: built here, never pulled

The repo is private, so there is no registry image and no registry token. The
script clones it, checks out the pinned commit and runs `docker compose build`
on this host. The image tag is the commit's short hash, so a new ref is a new
image, a new compose file and a restart; the older images are removed
afterwards. A full commit hash already in the clone needs no network.

## Update

Merge to main in the tutor repo, put the new commit hash in `SPANISH_TUTOR_REF`
in `lib/spanish-tutor.sh` (or pass it for one run), and re-run
`./provision/spanish-tutor-setup.sh`. A commit hash is written out in full; a tag
also works, and is fetched on every run.

## Tailscale serve

`tailscale serve --bg --https=8443 http://127.0.0.1:8096` publishes the app to
the tailnet. This is the lab's first `tailscale serve`, so the setup script
owns it. It reads `tailscale serve status --json` first and only runs the command
when the `:8443` entry is missing or points elsewhere. It is tailnet only. Never
`tailscale funnel`: the app has no login of its own and the tailnet is the only
access control. `verify-server.sh` fails if any Funnel is on.

```sh
tailscale serve status
tailscale serve --https=8443 off     # take it down
```

## Time zone

`TZ` in `tutor.env` is read from the host (`timedatectl`) on every run, so the
app's days, the daily new-card cap and the 02:30 nightly drill check follow the
server's clock (`America/Denver` on `ubuntu-home`), not UTC. Reading it beats a
constant: if the box's zone changes, a re-run fixes the app and the two never
disagree. `TUTOR_TZ=<zone>` overrides it, and `America/Denver` is the fallback
when `timedatectl` has no answer. The image has no zoneinfo database, so the
compose file mounts the host's `/usr/share/zoneinfo` read-only; without it the
container ignores `TZ`.

## Backups and restore

`spanish-tutor-backup.timer` runs `~/.local/share/spanish-tutor/backup` at 04:10,
after the 02:30 drill check. The host has no `sqlite3` binary and a file copy of
a live database can be torn, so the script runs python's `sqlite3` backup API
inside the container (`docker compose exec`, or a throwaway `run` if the
service is down):

- `data/backups/tutor-<date>-<time>.db`: a consistent copy, integrity-checked
  and deleted again if the check fails. The newest 14 are kept
  (`SPANISH_TUTOR_BACKUP_KEEP`).
- `data/backups/recordings/`: a plain copy of recordings not yet there, never
  overwritten. A recording deleted in the app stays in the backup.

A missed run (box off at 04:10) happens on the next boot. Check it:

```sh
systemctl list-timers spanish-tutor-backup.timer
journalctl -u spanish-tutor-backup -n 20 --no-pager
ls -lh ~/.local/share/spanish-tutor/data/backups/
```

The backups sit on the same disk as the data, so they cover a bad migration or
a deleted row, not a dead disk. Copying `data/backups/` to another machine is
not set up.

To restore:

```sh
sudo systemctl stop spanish-tutor
cd ~/.local/share/spanish-tutor/data
mv tutor.db tutor.db.bad
rm -f tutor.db-wal tutor.db-shm
cp backups/tutor-<stamp>.db tutor.db
sudo systemctl start spanish-tutor
curl -s http://127.0.0.1:8096/healthz
```

Recordings are only in `data/recordings/`; copy any missing file back from
`data/backups/recordings/`. Anything reviewed or logged after the backup is
lost, except reviews still queued on the phone, which sync when it is back on
the tailnet.

## Phone setup

Open `https://ubuntu-home.<tailnet>.ts.net:8443/` in Safari and Add to Home
Screen. The app repo's docs cover the rest:

- `docs/how-to/set-up-chatgpt-and-shortcuts.md`: the ChatGPT Project and the
  "Español" and "Log reporte" shortcuts.
- `docs/how-to/test-offline-on-iphone.md`: installing it and checking offline
  review and drills in airplane mode.

## Checking on it

```sh
curl -s http://127.0.0.1:8096/healthz
curl -s 'http://127.0.0.1:8096/api/brief?kind=speak' | head
systemctl status spanish-tutor spanish-tutor-backup.timer --no-pager
docker logs spanish-tutor-tutor-1 --tail 30
tailscale serve status
```
