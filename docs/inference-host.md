# The inference host

The local model server (a Strix Halo box with 128 GB of unified memory) is a
lab target like any other ([lab-access.md](lab-access.md)), tagged
`tag:lab,tag:inference`. It serves models and runs nothing else. Its setup is
the Ansible playbook in [`ansible/`](../ansible), run from the server.

## What the playbook does

| Part (`--tags`) | Does |
|---|---|
| `packages` | podman and crun, the llama.cpp Vulkan build tools, `hf`, and monitoring (lm-sensors, radeontop, nvtop). Adds your user to `render` and `video` |
| `memory` | Caps GTT at `inference_gtt_gib` (116 GiB) with `ttm.pages_limit`, in a grub.d drop-in. Purges kdump so `crashkernel=` stops reserving 2 GiB. Refuses a cap that leaves the OS less than 4 GiB |
| `llamacpp` | Builds a pinned llama.cpp with `-DGGML_VULKAN=ON` into `/opt/llama.cpp/<version>`, the fallback engine. Old builds are kept |
| `models` | `hf download` of each entry in `inference_models` at a pinned revision into `/models/<name>`. Resumable, and skipped once complete |
| `gufo` | Pulls Gufo by tag and digest, and writes a rootful podman quadlet that listens on the **tailnet address only**, since Gufo has no auth. Started only when `gufo_enabled` is true |

Every run ends by printing the live GTT cap, the GPU Vulkan sees, the active
llama.cpp build and Gufo's state.

The memory reasoning: the iGPU borrows system RAM through GTT rather than a
fixed BIOS carve-out, so the BIOS UMA buffer is at its minimum (2G) and the
kernel cap decides the split. In 4 KiB pages, 116 GiB is
`116 × 262144 = 30408704`.

## Running it

From the dev-environment checkout on the server:

```sh
ansible/play inference --check --diff     # preview; changes nothing
ansible/play inference                    # apply
ansible/play inference --tags models      # just the downloads (~130 GiB)
ansible/play inference -e inference_reboot=true   # apply and reboot if needed
```

`play` touches each host once over SSH first, so a pending Tailscale check
shows its URL rather than hanging Ansible. Then Ansible asks for your sudo
password (`BECOME password`). Kernel parameters need a reboot; the play says
so at the end and does not reboot unless asked.

Hosts come from [`inventory/tailnet.py`](../ansible/inventory/tailnet.py): every
tailnet peer tagged `tag:X` is in group `X`, reached through its
`<name>-admin` alias. No hostname is committed.

## Pins

| What | Where | Pinned to |
|---|---|---|
| Gufo image | `gufo_image` in role defaults | `0.23.0` plus digest |
| llama.cpp | `llama_cpp_version` | `v0.7.0` |
| Models | `group_vars/inference.yml` | Hugging Face commit per repo |
| GTT cap | `inference_gtt_gib` | 116 |

Gufo is pre-1.0 and releases near daily, and a newer llama.cpp build has broken
concurrent requests for others, so every bump is a deliberate edit and a
`--check --diff` first.

## Validation by hand

```sh
ssh evo-x2 'cat /sys/module/ttm/parameters/pages_limit'   # 30408704
ssh evo-x2 'vulkaninfo --summary | grep deviceName'
ssh evo-x2 'llama-bench -m /models/qwen3.8-27b/Qwen3.8-27B-UD-Q8_K_XL.gguf -ngl 999'
ssh evo-x2 'journalctl -u gufo -n 50'
curl http://evo-x2:8080/v1/models
```
