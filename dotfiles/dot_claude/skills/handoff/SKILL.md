---
name: handoff
description: Write HANDOFF.md at the repo root so a fresh session, another agent, or Will can pick the work up cold. Use on /handoff, or when asked to "write a handoff", "hand this off", "save where we are for the next session". Optional argument is what the next session is for. Not for the dev log (that is /log-session) and not for notes (that is the second-brain skill).
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

Write a handoff document for the current session to `HANDOFF.md` at the root
of the current git repo (outside a repo, the current directory). Overwrite any
earlier one: a handoff is the state now, not a history. History belongs in
commits and in the dev log.

If an argument was passed, it says what the next session will do. Write the
document for that task: lead with what it needs, drop what it does not.

## Gather first

- `git rev-parse --show-toplevel`, `git branch --show-current`,
  `git status --short`, `git log --oneline -5`, and `git stash list`.
- Open PRs or issues this session touched (`gh pr view`, `gh issue view`), if
  any.
- Live state the work depends on that a cold reader cannot see: running
  background jobs, clusters or contexts in use, port-forwards, tmux or herdr
  panes. Say how to check each one; do not assume it is still up.

## Template

Use these headings in this order. Leave out a section that would be empty,
except **Next steps**.

```markdown
# Handoff: <one-line goal>

<date> · repo `<name>` · branch `<branch>` · HEAD `<short sha>`
For: <the next session's task, if an argument was given>

## Goal
What we are trying to achieve and why, in two or three sentences.

## State
- Done and verified: what was changed and how it was checked (command, test, output).
- Done but not verified: changed, never confirmed working.
- Discussed only: agreed on, not started.

## Decisions
Each decision and the reason for it, so the next session does not reopen it.

## What didn't work
Approaches tried and why they failed, so they are not repeated. Quote the
deciding error line exactly.

## Working tree
Uncommitted changes and stashes, and whether each is meant to be kept.

## Live state
Background jobs, contexts, panes, port-forwards. How to check each one.

## References
Paths, PRs, issues, docs, artifacts. Link them, do not copy them.

## Next steps
1. Ordered, concrete actions. The first one should be startable without
   reading anything else.

## Open questions
Decisions waiting on Will, and things nobody knows yet.

## Suggested skills
Skills the next session should load, and for what.
```

## Rules

- The verified / not verified / discussed split is the point of the **State**
  section. Downgrade anything you only assumed. A confident claim that was
  never checked is the most costly thing a handoff can carry.
- Reference artifacts by path or URL. Do not paste specs, plans, diffs or logs
  that already exist somewhere.
- Redact secrets: tokens, passwords, kubeconfig contents, anything from
  `~/.lab.env`. Say where the secret lives instead.
- Keep it short. Aim for something a person reads in two minutes. If it runs
  past about 80 lines, cut detail that a reference already holds.
- Write plain prose, not caveman style: the reader starts cold.

## Keep it out of git by default

If `HANDOFF.md` is not tracked and not already ignored
(`git check-ignore -q HANDOFF.md` fails), add `HANDOFF.md` to
`.git/info/exclude`. That ignores it locally without changing the repo. If it
is already tracked, the repo wants it committed: leave it and say so.

## Finish

Tell Will the path and give a one-line prompt to start the next session with:

```
claude "/resume-handoff"
```
