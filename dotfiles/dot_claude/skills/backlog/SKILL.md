---
name: backlog
description: Read from and add to Will's personal backlog, a private GitHub Projects board of topic-level items with sub-task checklists. Use to add — "add this to the backlog", "backlog this", "track this for later", a brain dump of things to do — and to retrieve — "what's on my backlog", "what's next", "what should I work on", "what's open for this repo", "do I have a backlog item about X", "what's left on <topic>". Also use on /backlog. Not for work that belongs in the current repo's own issue tracker unless he asks for it on the backlog.
argument-hint: [what to add, or a question about the backlog]
---

The backlog is a private, user-level GitHub Projects board that sits above
every repo. Items are draft items by default, so nothing needs a repo to live
in. This skill reads it and adds to it.

Three scripts know the project and its fields: `backlog-list` reads,
`backlog-add` creates a topic and resolves field names to ids, and
`backlog-subtask` adds or ticks a sub-task inside a topic. Do not call
`gh project item-create` directly.

```
backlog-add [-s status] [-p priority] [-k kind] [-a area] [-b body|-] [-u url] [title]
```

| Flag | Field | Values |
|---|---|---|
| `-s` | Status | `Inbox` (default), `Next`, `In Progress`, `Done` |
| `-p` | Priority | `High`, `Medium`, `Low` |
| `-k` | Kind | `Tech`, `Idea`, `Chore`, `Personal` |
| `-a` | Area | free text: a repo or topic name |

## Reading the backlog

For "what's on my backlog", "what's next", "what's open for <repo>", "do I
have anything about X", "show me the <topic> item", use `backlog-list`. It is
one cheap query; do not use `gh project item-list`, which burns the hourly
API budget.

```
backlog-list [-s status] [-p priority] [-k kind] [-a area] [-q text] [-A] [-v] [-j]
```

- No flags: every topic that is not Done, ordered In Progress, Next, Inbox,
  then by priority.
- `-s next`, `-k idea`, `-a gpu-lab` (substring), `-q spiffe` (title or body)
  narrow it. Matching is case-insensitive.
- `-v` adds each body, which is where the sub-task checklists are. Use it when
  the question is about what is left inside a topic.
- `-A` includes Done. `-j` gives JSON for anything the flags cannot express.

Answer the question asked, not a dump of the board: for "what's next", lead
with In Progress and Next and the unchecked sub-tasks in them; for a topic,
show its open sub-tasks. When working in a repo, `-a <repo-name>` is the
relevant slice. Reading never changes anything.

## Items are topics, not tasks

An item is a bigger topic — a piece of work with a goal, like "AgentMinder
workload identity with SPIFFE" — and the individual things to do live inside
it as a checklist in the body. "Try missions with a SPIFFE subject" is a
sub-task of that topic, not an item of its own. A board of thirty one-line
tasks is the failure mode.

So before adding anything, look at what is already there:

```
backlog-list -A
```

If the new thing belongs under an existing topic, add it to that topic's
checklist instead of creating an item:

```
backlog-subtask <topic> <task text>      # append "- [ ] <task text>"
backlog-subtask -x <topic> <task text>   # tick the sub-task matching the text
backlog-subtask -u <topic> <task text>   # untick it
```

`<topic>` is part of the title (case-insensitive) or the `DI_…` id from
`backlog-list`. With `-x` / `-u` the task text is a fragment of an existing
line. Both must match exactly one thing; on an ambiguous match the script
lists the candidates and changes nothing, so retry with a longer fragment
rather than guessing. Use `-x` when he says a sub-task is done ("I sent the
questions to the AgentMinder team"). When every sub-task of a topic is ticked,
say so — moving the topic to Done is his call.

Rewording or deleting a sub-task has no flag: write the whole body back with
`gh api graphql` and `updateProjectV2DraftIssue(input: {draftIssueId, body})`,
taking the current body from `backlog-list -j -q "<title>"`.

Create a new item only when no existing topic fits.

## Steps

1. Work out the topics from `$ARGUMENTS` and the conversation. Group related
   tasks under one topic; a brain dump of ten tasks is usually two or three
   topics. If asked to backlog "this" with no description, the topic is
   whatever was just being discussed.
2. For each new topic, write:
   - **Title**: the topic, specific enough to make sense in six months with
     no context ("vkstack: correctness and upgrade-path work", not "vkstack
     stuff"). A noun phrase is fine; it does not have to be imperative.
   - **Body**: one or two sentences on the goal and where it came from, then
     the sub-tasks as a markdown checklist, one `- [ ]` line each, concrete
     enough to act on (commands, paths, flags in backticks). Use `- [x]` for
     ones already done. A topic with a single obvious task needs no checklist.
3. Set fields only where the answer is clear:
   - **Kind**: `Tech` for code, infra, or tooling work; `Idea` for something to
     explore, not yet a task; `Chore` for maintenance and admin; `Personal`
     for anything outside tech.
   - **Area**: the repo name when the item is about a repo (default to the
     current repo if the item came out of work in it), otherwise a short topic.
     Leave it off when nothing fits.
   - **Priority**: only when he states one or it is plainly implied
     ("urgent", "someday"). Do not guess; unset is a valid answer and gets
     decided at triage.
   - **Status**: leave at `Inbox` unless he says it is up next or in progress.
4. Run `backlog-add` once per new topic. Pass a body with `-b -` and a quoted
   heredoc so nothing in it gets expanded. Without `-b -` stdin is ignored and
   the heredoc is silently dropped:
   ```
   backlog-add -k Tech -a dev-environment -b - "Reproducible server bootstrap" <<'EOF'
   An unpinned install picked up a breaking release once already.

   - [ ] Pin the chezmoi version in `provision/server-bootstrap.sh`
   - [ ] Checksum the download, the way the Go install does
   EOF
   ```
   For an existing issue or PR, add it by URL instead of creating a draft:
   `backlog-add -u <url> -p High`.
5. Report what was added: one line per item with its fields. No recap beyond
   that.

## What does not belong

The backlog is for work worth coming back to: a feature, a fix, an
investigation, a decision, a bug to file, a post to write. It is not a to-do
list for housekeeping. Unless he names the item himself, leave out:

- cleanup after a session: tearing down lab or test state, deleting throwaway
  clusters, removing temp files or leftover permission rules
- commit, push, tag, or "nothing committed yet" reminders
- one-step confirmations and re-checks ("verify X settled", "confirm Y is up")
- anything that takes a few minutes and would be done in passing anyway

This matters most when pulling items out of notes, logs, or a session's
follow-ups in bulk: most follow-up lines are this kind of thing, and old ones
are often already done. Take the few that are real work, skip the rest, and
say how many were skipped. When he asks for a specific item by name, add it
whatever its size.

Do not ask for confirmation before adding — a wrong item costs one click to
fix, and the point of this is cheap capture. Ask only when it is unclear what
the item even is.

## When it fails

- `missing required scopes [project]` — the `gh` token lacks the scope. He has
  to run `gh auth refresh -s project` and approve it in a browser. On a
  headless box that is the device flow: the command prints a one-time code to
  enter at https://github.com/login/device from any machine.
- `no <Field> option "<value>"` — the board's options changed. The error lists
  the current ones; use one of those.
