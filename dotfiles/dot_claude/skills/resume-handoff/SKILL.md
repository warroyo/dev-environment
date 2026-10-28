---
name: resume-handoff
description: Pick up work from the HANDOFF.md that the handoff skill wrote at the repo root. Reads it, checks what changed since it was written, briefs Will, and stops. Use on /resume-handoff, or when asked to "resume from the handoff", "pick up where we left off", "read the handoff".
disable-model-invocation: true
---

Read `HANDOFF.md` at the root of the current git repo (outside a repo, the
current directory). If there is none, say so and stop.

## Check for drift

The handoff is a claim about the past. Check it before trusting it:

- Compare the branch and HEAD in its header with `git branch --show-current`
  and `git rev-parse --short HEAD`. If HEAD moved, list the new commits with
  `git log --oneline <old sha>..HEAD`.
- Compare its **Working tree** section with `git status --short` and
  `git stash list`.
- For each item under **Live state**, run the check it gives. Mark each one
  still up, gone, or not checked.
- Note how old the handoff is.

Do not re-verify everything under **State**. Treat "done but not verified"
items as unverified until a check says otherwise.

## Brief, then stop

Give Will a short briefing:

1. The goal, in one line.
2. What changed since the handoff, from the drift check. Say "nothing" if
   nothing did.
3. The first next step, and any open question that blocks it.

Load the skills listed under **Suggested skills** only when the work reaches
them.

Then stop and wait. Do not start the next steps until Will says to. The
handoff may be stale, and he may want to change direction.
