---
name: hermes
description: Hand work to the local Qwen model on the EVO-X2 to save Claude tokens, either as a one-shot `ask-qwen` call with the input piped in or as a job for Hermes Agent when the model has to find its own input. Use when Will says "hermes", "local model", "give this to the local model", "delegate this" or "run it locally", and offer it unprompted for high-input, low-output work: triaging logs or cluster state in the home lab or client lab, summarizing many documents, reading through a big directory or a docs site to answer one question, bulk extraction into a table. Not for coding (that stays with Claude and Codex), and not for anything needing back-and-forth.
---

Hermes runs on `ubuntu-home` against LiteLLM (`http://127.0.0.1:4000/v1`,
model `local-qwen`). Two profiles. Setup is `provision/local-ai-setup.sh` in
the dev-environment repo; the design is in its `docs/local-ai.md`.

| Profile | Use for | Access |
|---|---|---|
| `lab` (default) | anything touching the home lab or client lab | the same as Claude: host shell, `~/.lab.env`, agent SSH, `tun0`. No admin SSH, no ansible |
| `restricted` | internet research, notes for the vault | internet only, in a container. Writes only to `/inbox` (the vault's `inbox/`) |

The home lab and the client lab are not sensitive, so anything Claude may work
on may be delegated. Hermes gathers lab data itself; there is no need for
Claude to collect it first.

## When it saves tokens

Delegating costs Claude the brief plus whatever it reads back, so it pays off
only when Hermes reads far more than it returns.

| Delegate | Keep |
|---|---|
| Triage 24h of llama-swap logs down to what matters | Anything where checking the answer means re-reading the source |
| Survey a VKS cluster's events and pod states for problems | Coding, reviews, design decisions |
| Summarize 50 docs into one page | Short jobs: the brief would cost more than doing it |
| Read a vendor's docs site and answer one question | Work needing several rounds of clarification |

Local models are wrong more often than Claude. Delegate work where a wrong
answer is cheap to spot, and spot-check it.

## ask-qwen or Hermes

Pick by who does the reading.

| `ask-qwen` | Hermes |
|---|---|
| The input is already known: a log, a file set, a command's output | The model has to decide what to read next: SSH to hosts, follow leads, browse a docs site |
| One question per input, or the same question per chunk | Several steps with tools |
| Seconds to minutes, no pane, nothing to clean up | A herdr worker, a brief and a job folder |

### ask-qwen

Pipe the input in from Bash; never read it into this session first, or
nothing is saved.

```bash
journalctl -u litellm --since -24h | ask-qwen -f - "List distinct errors, one line each, with a count"
kubectl get pods -A -o json | ask-qwen -q -s '{"type":"object","properties":{"failing":{"type":"array","items":{"type":"string"}}},"required":["failing"],"additionalProperties":false}' -f - "Which pods are not Running or Completed?"
ask-qwen -q -f docs/a.md -f docs/b.md "Every version number mentioned, as a markdown table"
```

- `-f -` reads stdin; nothing else does. `-f <file>` is repeatable.
- `-s <schema>` (a file or inline JSON) forces a JSON answer, so the result
  can be checked with `jq` before it is trusted.
- `-q` turns thinking off: use it for extraction, filtering and
  reformatting. Leave thinking on for triage that needs judgement; it is
  slow (minutes on a 30k-token log).
- Exit 4 means the input is over about 100k tokens: split it
  (`split -l`, one file per host, one namespace at a time) and run one call
  per chunk, then merge the answers yourself or with one more call. Requests
  run one at a time on the EVO-X2, so `xargs -P 2` at most.
- Exit 3 means the answer hit the `-n` cap; raise it or add `-q`.
- The first call after a model swap waits 1-2 minutes. That is not a hang.

The same rule as for Hermes: spot-check a claim or two before reporting.

## Hermes steps

1. **Write a brief.** Hermes starts with no context of this session, so the
   brief carries everything: goal, where to look (hosts, clusters, URLs), what
   done looks like, and the output contract. Read-only: tell it to find and
   report, not to fix. Fixes go through dev-environment code.

   For `lab`, include:
   > For any Python, write the script to a file in `~/hermes-work/<topic>/`
   > and run `python3 <file>`. Never use `python3 -c` or a heredoc
   > (`python3 - <<EOF`): those stop for approval and stall the job.

   Hermes' approval check flags inline code (`-c`, heredoc) but not a script
   file, so this keeps a lab job unattended without loosening approvals.

   End the `lab` brief with:
   > Write the full result to `~/hermes-work/<topic>/result.md`. Then write
   > `~/hermes-work/<topic>/summary.md`: at most 15 lines with the answer,
   > anything you could not do, and what you are unsure of.

   For `restricted`, include the same rule with `/tmp/` in place of
   `~/hermes-work/<topic>/` (the container cannot see `~/hermes-work`). Use
   `/inbox/hermes-<topic>.md` for the result and put the summary at the top of
   that file.
   ```bash
   mkdir -p ~/hermes-work/<topic>   # lab jobs
   ```

2. **Find or make the `workers` workspace.** Hermes runs there, never split
   beside this pane.
   ```bash
   herdr workspace list | jq -r '.result.workspaces[] | select(.label=="workers") | .workspace_id'
   herdr workspace create --label workers --cwd ~/hermes-work --no-focus   # only if none
   herdr pane list --workspace <workspace_id>                               # a pane at a shell prompt
   ```
   If every pane there is busy, `herdr pane split` one.

3. **Start the worker and hand it the brief.**
   ```bash
   herdr agent start hermes-<topic> --kind hermes --pane <pane_id>                     # lab
   herdr agent start hermes-<topic> --kind hermes --pane <pane_id> -- -p restricted    # restricted
   herdr agent prompt hermes-<topic> "Read ~/hermes-work/<topic>/brief.md and carry out the task it describes."
   ```
   Always a one-line prompt pointing at the brief: a multi-line prompt pasted
   through herdr does not get submitted in Hermes's input box. For a
   `restricted` job, put the brief in `~/second-brain/inbox/` and point at
   `/inbox/<file>`, since that is the only host path it can see. Check the
   pane afterwards (`--source visible --lines 6`): the prompt should show in
   the status line and the spinner should be running.

4. **Wait in the background until it stops working.** State comes from the
   `herdr-push-state` Hermes plugin (provisioned by `lib/hermes.sh`), so
   `herdr agent wait` works. Run it as a background Bash command:
   ```bash
   herdr agent wait hermes-<topic> --until done --until idle --until blocked --timeout 3600000
   ```
   herdr's own screen detection does not know the current Hermes TUI
   (herdrdev/herdr#5336); without the plugin the state is `idle` throughout.
   If the state never leaves `idle` after the prompt, the plugin is not
   reporting: fall back to polling for `summary.md`.

5. **When it settles, read the summary, not the pane.** Scrollback is where
   the tokens go.
   ```bash
   herdr agent get hermes-<topic>
   cat ~/hermes-work/<topic>/summary.md
   ```
   - `done` or `idle`: report the summary to Will and point at `result.md`.
     Spot-check one or two claims with a targeted command (a `grep`, one
     `kubectl get`). Open `result.md` only when he needs the detail.
   - No summary file: read the last 40 lines only,
     `herdr agent read hermes-<topic> --source recent-unwrapped --lines 40`.
   - `blocked`: Hermes is asking for approval of a command, memory write or
     skill write, or a clarifying answer. Read the last 40 lines, quote the request to Will word for
     word, say what you would answer and why, and send a push notification if
     he may be away. Answer only with his go-ahead, using
     `herdr agent send-keys`, which always prompts. Never approve on Hermes'
     behalf yourself.

6. **Clean up.** Once the summary is read and reported, close the worker's
   pane; the result lives in `~/hermes-work/<topic>/`, not the session.
   ```bash
   herdr pane close <pane_id>
   ```
   Keep it open only while it is `blocked` and waiting on Will, or when he
   asks to keep it or plans a follow-up in the same session. Start a new
   worker for an unrelated job so its context starts clean. Before starting
   one, close any idle `hermes-*` panes left in `workers` by earlier jobs.

## Checks when it fails

- `curl -s -m 5 http://127.0.0.1:4000/health/liveliness` answers if LiteLLM
  is up; `systemctl status litellm` and
  `docker compose -f ~/.local/share/litellm/compose.yaml logs --tail 50 litellm`
  if not.
- The first request after a model swap takes 1-2 minutes while llama-swap
  loads the model. That is not a hang.
- State stuck at `idle` while Hermes visibly works: check
  `hermes plugins list` shows `herdr-push-state` enabled and
  `terminal.client_env_passthrough` lists the `HERDR_*` names. Each turn runs
  in the profile's shared gateway, and those names are how it knows which
  pane the session came from. A pane that had state pushed by hand can stay
  stuck; start the worker in a fresh pane.
