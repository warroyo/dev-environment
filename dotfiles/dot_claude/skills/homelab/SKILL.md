---
name: homelab
description: Ground any answer about Will's home lab in its current recorded state before replying. Use whenever a question or task touches the lab or how he reaches it, even indirectly - its machines (ubuntu-home, the EVO-X2, homeNAS, the Plex box, the spare laptops, glkvm), the tailnet, SSH or remote access (including from a phone or another client), herdr/tmux sessions, the local AI stack (LiteLLM, Hermes, llama-swap, models), Plex and the *arr stack, monitoring, the client-lab tunnel, or a purchase or upgrade for the lab. Also use for generic-sounding questions ("what SSH client should I use", "should I buy X") when the answer depends on what the lab already runs. Not for the client lab's VCF/VKS internals (that is lab-creds and the vkstack tools).
---

Will's lab changes week to week, and general advice that ignores what is
already decided or built is wrong for him. Read the current state first, then
answer in terms of it. Never answer a lab question from general knowledge
alone.

## Where the state lives

| Source | What it holds |
|---|---|
| `~/second-brain/topics/homelab.md` | The hub: machines and their status, how they connect, dated decision history, open questions. Read this every time. |
| Notes it links (`~/second-brain/notes/`) | Per-machine and per-stack detail: `evo-x2-inference-server.md`, `local-ai-stack.md`, `ubuntu-home-workstation-upgrade-plan.md`, `spare-laptops-in-the-lab.md`, `lab-architecture.md` (diagrams). Read the ones the question touches. |
| `~/workspace/dev-environment` | What is actually built, as code. `docs/ARCHITECTURE.md` (roles, how clients reach the server, phone access), `docs/lab-access.md` (Tailscale SSH, tags, `agent` account), `docs/local-ai.md`, `docs/inference-host.md`, `docs/lab-metrics.md`, client setup docs. `ansible/` and `provision/` are the source of truth for config. |
| The live machines | Current runtime state, when the question is about what is running now. Query through the no-sudo `agent` account over the tailnet; read only. |

The vault records decisions and plans; the repo records what was built. When
they disagree, say so: either the vault is stale or the code has not caught up.
Check `git -C ~/workspace/dev-environment log --oneline -10` and open branches
for work in flight that neither shows yet.

## How to work

1. Read the hub, then grep the vault and the repo for the subject of the
   question (`rg -i <term> ~/second-brain/topics ~/second-brain/notes ~/workspace/dev-environment/docs`).
2. Answer against what you found. Name the existing pieces the answer builds
   on, and point out where a generic recommendation would clash with a
   decision already made.
3. If the answer changes or adds to the lab plan, offer to record it in the
   vault (through the `second-brain` skill) and, for anything that changes a
   machine, in the dev-environment repo as code.

## Rules that always apply

- Lab changes are code in dev-environment: bash for first boot, Ansible for
  managed targets, chezmoi for dotfiles. Never propose a hand change over SSH;
  a fix found live goes into the repo and is applied by running it.
- `ubuntu-home` is the only agent host. Other machines are targets or clients.
- The work laptop is out of scope beyond what dev-environment's `work` role
  already gives it.
- Write lab notes to the vault only through the `second-brain` skill, never as
  loose markdown in `~/workspace/homelab_upgrades/`.
