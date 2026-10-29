# Will's machine: global instructions for Codex

This is the Codex counterpart of `~/.claude/CLAUDE.md`. Both are managed by
`~/workspace/dev-environment` (chezmoi). Edit the source there, not this copy.

Claude Code is the main coder and orchestrator here. Codex does reviews and
some coding, either driven from Claude through the codex plugin or in its own
sessions. Codex setup and provisioning live in `~/workspace/dev-environment`.

## Skills

The skills in `~/.codex/skills` are links to the Claude Code ones in
`~/.claude/skills`, so the two agents share one set. Some of them name Claude
Code tools (for example `AskUserQuestion` or the `Skill` tool). Use the Codex
equivalent, or ask in plain text.

## The home lab and the client lab

- Before answering anything about the lab, use the `homelab` skill. It reads
  the current state from `~/second-brain/topics/homelab.md` and the notes it
  links. Do not answer lab questions from general knowledge alone.
- For the client lab (`*.set.lab`: vCenter, the Supervisor, VCF Automation,
  Cloud Foundry), use the `lab-creds` skill to get or refresh credentials
  before asking Will to log in by hand.
- The home lab and the client lab are not sensitive. Work in both directly.
  The work laptop is out of scope: never propose installs, agents or data
  flows that involve it.
- Every install or change on lab machines goes through code in
  `~/workspace/dev-environment`: bash for first boot, Ansible for what
  ubuntu-home manages over SSH, chezmoi for dotfiles. On live machines, only
  query and troubleshoot, through the no-sudo `agent` account. Do not install
  packages, edit config or change state by hand over SSH. Put a fix in the repo
  and apply it by running the code.
- Credentials never go into docs, notes or commits.

## The second-brain vault

`~/second-brain` is Will's private Obsidian vault. Its `entries/` folder is the
dev log; `topics/`, `notes/` and `inbox/` hold notes.

- To save a note, write or update a topic, or look up what the notes say, use
  the `second-brain` skill. It writes through `vault-note`, which puts the file
  in the right folder with the right frontmatter.
- Never create or edit a file in `~/second-brain` directly, and never edit
  anything in `entries/`.
- Writing a dev-log entry is manual (the `log-session` skill). Suggest it when
  something clearly worth keeping happened: a decision and its reason, a
  breakage and its fix, a reusable command, an open follow-up. Do not run it
  unasked.

## Sandbox network

Sessions started with `cx` or `codex-open` have network in the
workspace-write sandbox, which kubectl, ssh and curl against the labs need. A
session started any other way (plain `codex`, or a new thread from the ChatGPT
app) may not. If lab commands fail with "Could not resolve host", that is the
cause. Tell Will rather than working around it.
