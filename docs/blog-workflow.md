# Blog workflow: dev-log entry → published post

Turning raw session material in `~/dev-log` into a post on
[blog.warroyo.com](https://blog.warroyo.com/), without the agent writing the
prose and without the private log leaking into a public repo.

Server only. Everything here depends on Claude Code, which is installed on no
other machine — see [ARCHITECTURE.md](ARCHITECTURE.md#roles).

## The six steps

Each one is triggered by hand. Nothing runs on a schedule or on its own.

| | Command | What it does |
|---|---|---|
| 1 | `/post-ideas` | Reads every dev-log entry, drops ones already claimed by a pitch, groups the rest, ranks them as post candidates |
| 2 | `/post-brief <slug>` | Builds the brief **and walks its redaction list with you.** The gate |
| 3 | `/post-scaffold <slug>` | Branch, front matter, headings, code blocks, `<!-- TODO -->` where prose goes |
| 4 | — | Cloudflare builds the branch; open the preview URL on your phone |
| 5 | — | Dictate the prose into the stubs |
| 6 | `/post-ship <slug>` | Re-scan for leaks, check front matter and images, open the PR |

Steps 1–2 run anywhere on the server. Steps 3 and 6 run inside
`~/workspace/warroyo-blog`.

## Why it is split across two repos

`~/dev-log` is private and deliberately unfiltered — internal command output,
cluster names, vendor detail, half-formed notes. `warroyo-blog` is public. The
two commands that read the log stay private; the two that only know Hugo are
committed to the blog repo itself.

| Piece | Lives in | Why there |
|---|---|---|
| `/post-ideas`, `/post-brief` | this repo, `dotfiles/dot_claude/commands/` | Read the private log. Role-gated to the server in `.chezmoiignore.tmpl` |
| `DEV_LOG_PITCHES` | this repo, `dotfiles/dot_zshenv` | Lets the public commands find the brief without hard-coding the private path |
| repo clones | this repo, `provision/lib/repos.sh` | Both repos are infrastructure, not incidental checkouts |
| `pitches/` staging | the `dev-log` repo | Private by construction |
| `/post-scaffold`, `/post-ship`, `blog-style.md` | the `warroyo-blog` repo | Only know Hugo. Public is fine, and they travel with the site they describe |

**The brief is the only thing that crosses.** Nothing copies dev-log content
into the blog automatically. `/post-brief` flags every hostname, cluster name,
credential, customer name and unreleased feature it finds, proposes a
replacement for each, and will not mark the brief `pitched` until you have
answered all of them. `/post-ship` re-scans the finished post against that same
list, because step 5 is dictation and you can say something you shouldn't
publish.

## Why the prose is not written for you

`/post-scaffold` produces headings, code blocks copied **verbatim** from the
log, image placeholders, and one-line TODO stubs. It writes no sentences.

Step 5 is you talking. Open a session on the blog repo from the phone —
`/cc_open warroyo-blog` in Telegram, then the Remote Control link into the
Claude app — read a stub, say the paragraph. The rule in the blog repo's
`.claude/blog-style.md` is that your words go in as you said them, with
transcription artifacts fixed and nothing else touched. If a sentence is
unclear it gets a question, not a repair.

## Previews

Cloudflare Pages reports back to GitHub as a **check run** named
`Cloudflare Pages` — not a commit status and not a GitHub Action, so
`/commits/<sha>/status` and the `deployments` API are both empty and misleading.
The URL is in the check run's `output.summary`:

```bash
gh api "repos/warroyo/warroyo-blog/commits/$(git rev-parse HEAD)/check-runs" \
  --jq '.check_runs[]|select(.name=="Cloudflare Pages")|.output.summary' \
  | grep -oE 'https://[a-z0-9.-]+\.pages\.dev'
```

Two flavors, and the difference matters:

- **per-deployment** — `https://6221a8b3.warroyo-blog.pages.dev`, new hash every
  push
- **branch alias** — `https://post-<slug>.warroyo-blog.pages.dev`, stable for the
  life of the branch (Cloudflare turns the `/` in `post/<slug>` into `-`)

The branch alias is the tab you keep open on the phone and reload after each
dictated paragraph. `/post-scaffold` prints it.

Posts are scaffolded with `draft: false` on purpose: that is what makes them
render on the preview without `HUGO_BUILDDRAFTS` set in the Pages Preview
environment, and they still cannot reach production until the PR merges.

There is no local preview on the server — Hugo and Go are not installed there,
and `localhost:1313` is no use from a phone regardless.

## Setup

`server-bootstrap.sh` clones both repos (`provision/lib/repos.sh`). It sets up
no GitHub credentials of its own, so on a fresh machine the private `dev-log`
clone will fail with a warning rather than aborting the run — add a key, then
re-run. `verify-server.sh` reports anything that did not land.
