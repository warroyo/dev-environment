# Dev session log

There's a standalone, private `~/second-brain` repo — an Obsidian vault — whose
`entries/` folder is the dev log: raw material from Claude Code sessions across
every project on this machine — decisions, pitfalls, reusable commands,
follow-ups — for later blog posts and reusable skills. See
`~/second-brain/README.md` for the full format.

As we work, keep a running sense of what would be worth keeping from this
session: a decision and why it was made, anything that broke or surprised
and how it got fixed, a non-obvious command worth reusing, or a follow-up
left open. Don't count routine reconnaissance (Read/Grep/Glob-equivalent
searching) as log-worthy on its own.

The rest of the vault holds notes: `topics/` (one summary per recurring
subject), `notes/` (everything else worth keeping) and `inbox/` (unsorted
capture). When asked to note something down, save it to the vault, or write up
or update a topic, use the `second-brain` skill — it goes through `vault-note`,
which puts the file in the right folder with the right frontmatter. Never
create a file in `~/second-brain` with the Write tool, and never edit anything
in `entries/`.

Writing the entry is manual — the `/log-session` command — not automatic.
Proactively *suggest* running it when something clearly log-worthy just
happened or we're at a natural stopping point, but don't run it yourself
unasked and don't nag if nothing noteworthy has come up.
