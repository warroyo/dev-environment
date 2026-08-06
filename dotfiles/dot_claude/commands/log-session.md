---
description: Write or append a dev session log entry to ~/dev-log now
argument-hint: [note to include]
---

Write a dev session log entry for the current project to the standalone
`~/dev-log` repo, right now (see `~/dev-log/README.md` for the format).

1. Determine the project slug: the current git repo's top-level directory
   name (`basename "$(git rev-parse --show-toplevel)"`), lowercased and
   hyphenated. If not inside a repo, use the current directory name instead.
2. From this conversation so far — plus `$ARGUMENTS` if given, treat that as
   something the user specifically wants included — draft a short, scannable
   entry using only the sections that actually apply; omit any with nothing
   to say:
   - **Project / repo**
   - **Decision** — what was decided and why (1-3 sentences)
   - **Pitfall** — anything that broke, surprised, or wasted time, and the fix
   - **Commands** — non-obvious or reusable commands worth keeping
   - **Follow-ups** — anything left open
   Skip routine tool calls (Read/Grep/Glob-equivalent reconnaissance) —
   capture decisions, pitfalls, outcomes, and reusable commands only. This
   should read well months from now, not like a transcript.
3. Pipe that markdown body to the shared writer, which handles creating this
   session's file or appending to it with a `---` separator:
   ```
   dev-log-entry -p <slug> <<'EOF'
   ...
   EOF
   ```
   Each Claude Code session gets its own file — the writer reads
   `$CLAUDE_CODE_SESSION_ID` from the environment itself, so don't pass `-s`
   and don't try to look the session id up.
4. Tell the user what was written and where (the writer prints the path).

If there is genuinely nothing worth logging yet this session, say so plainly
and don't write anything.
