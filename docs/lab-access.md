# Lab access: how agents SSH into the other machines

Claude Code and Codex run on the server and nowhere else. Every other lab
machine is a **target**: agents SSH into it to read logs, check services, and
restart them. Nothing agent-related is installed on a target.

## How it fits together

```
server (untagged, yours)                       target (tag:lab)
  claude / codex                                 sshd: LAN only, keys only
  ssh <target>        ──── tailnet ────▶  Tailscale SSH  ──▶  agent   (accept)
  ssh <target>-admin  ──── tailnet ────▶  Tailscale SSH  ──▶  <you>   (check)
```

- **Identity is Tailscale's.** Tailscale SSH answers port 22 on the target's
  tailnet address and authorizes by the tailnet policy, so there are no
  `authorized_keys` to manage for agent access.
- **The account is the scope.** Agents run as you on the server, so on the
  tailnet an agent and you look the same. The difference is which account
  they log in as on the target:
  - `agent`: no password, no sudo, in `systemd-journal` and `adm` so it can
    read logs, with lingering on so its own user services outlive a session.
    Accepted with no prompt.
  - your own account (named in the policy's check rule): has passwordless
    sudo, and needs a Tailscale **check**. The first connection prints a login
    URL and waits. Opening it is the approval, and it holds for 12 hours.
- **Targets are tagged.** A tag takes the machine out of your ownership, so it
  cannot start connections into the tailnet. Only the SSH rules let anyone in.
- **The LAN stays a fallback.** sshd still serves the LAN, keys only, for when
  Tailscale is down.
- **The server takes Tailscale SSH too**, for you rather than for agents: your
  devices (laptop, phone) SSH into it as your account, under the policy's
  `autogroup:self` check rule. It stays untagged, because a tagged server could
  not start the connections agents make. Enabled by `server-bootstrap.sh`.

The pieces:

| File | Does |
|---|---|
| [`policy/tailnet.hujson`](../policy/tailnet.hujson) | Tags and SSH rules. Pasted into the admin console by hand |
| [`provision/lab-target-bootstrap.sh`](../provision/lab-target-bootstrap.sh) | Run once per target: Tailscale SSH plus tags, the `agent` account, sshd keys-only |
| `lab-ssh-config` ([source](../dotfiles/dot_local/bin/executable_lab-ssh-config)) | Run on the server: writes the `<target>` and `<target>-admin` aliases from the tailnet |
| [`ansible/lab.yml`](../ansible/lab.yml) | Run from the server with `ansible/play lab`: what every target has (role `lab_target`) |

No hostname appears in any of them. The host list is whatever the tailnet
says is tagged `tag:lab`.

## Setup

### Once: the tailnet policy

1. Open <https://login.tailscale.com/admin/acls/file>.
2. Diff the live policy against [`policy/tailnet.hujson`](../policy/tailnet.hujson)
   and carry over anything the live one has that this file lacks. Saving
   replaces the whole policy.
3. Paste, check the preview, and save.

### Per target

On a fresh Ubuntu install, from the server, over the LAN:

```sh
ssh-copy-id <you>@<lan-ip>          # so the LAN fallback has a key
scp provision/lab-target-bootstrap.sh <you>@<lan-ip>:
ssh -t <you>@<lan-ip> sudo ./lab-target-bootstrap.sh
# model server during build-out:
ssh -t <you>@<lan-ip> sudo LAB_TAGS=tag:lab,tag:inference ./lab-target-bootstrap.sh
```

`tailscale up` prints a login URL unless you pass `TAILSCALE_AUTHKEY`. Then,
back on the server:

```sh
lab-ssh-config
ssh <target> 'journalctl -n 20'
ssh <target>-admin 'sudo -v'         # opens the browser check once
```

Re-run `lab-ssh-config` whenever a target joins, leaves, or is renamed.

Then give your account passwordless sudo. This is the one run that asks for
your sudo password:

```sh
ansible/play lab -K
```

## Privileged changes

Every install or change on a target is code in this repo, applied by running
it. Agents read and troubleshoot through `agent`; they do not change a target
by hand. A fix found while troubleshooting goes into a playbook, gets a
`--check --diff`, and is applied with `ansible/play`.

Two approvals stand between an agent and root on a target:

| Approval | Who | Where it is enforced |
|---|---|---|
| Tailscale check on your account | You, in a browser, every 12 hours | Tailscale, outside the server |
| A permission prompt on each `ansible/play` run | You, in the agent session | The agent harness (Claude Code settings) |

Sudo itself asks for nothing: your account has `NOPASSWD: ALL` from role
`lab_target`, so Ansible runs unattended once the check has passed. The cost:
for those 12 hours, anything running as you on the server can get root on the
targets. The harness rules narrow that for agents. In Claude Code, chezmoi
merges these into `~/.claude/settings.json` on the server
([`modify_settings.json`](../dotfiles/dot_claude/modify_settings.json)),
keeping every other key and any rule added by hand:

```json
"permissions": {
  "ask":  ["Bash(*ansible/play*)"],
  "deny": ["Bash(ssh *-admin*)", "Bash(ansible *)", "Bash(*ansible-playbook*)"]
}
```

`ssh <target>-admin` and ad-hoc `ansible` are denied, so the only privileged
path is a playbook run you confirm. Answer that prompt once each time; an
"always allow" turns the second approval off. Harness rules are a guardrail
for an agent that follows them, not a security boundary: another tool on the
server, or a command written to dodge the pattern, is not stopped by them.
The Tailscale check is the boundary.

To go back to a sudo password, set `lab_admin_nopasswd: false` and run
`ansible/play lab`, then put `become_ask_pass = True` back in
[`ansible.cfg`](../ansible/ansible.cfg).

## Tightening later

- **Make a target API-only.** Remove `tag:lab` and keep `tag:inference`. The
  SSH rules stop matching it, and the policy can then grant the API ports
  alone. The planned end state for the model server.
- **Let `agent` restart one system service.** Add a sudoers drop-in to role
  `lab_target` naming that exact command, for example
  `agent ALL=(root) NOPASSWD: /usr/bin/systemctl restart gufo`. Never a
  wildcard.
- **Apply only merged code.** Replace the passwordless-sudo path with
  `ansible-pull` on each target, run from a systemd timer against `main`, so
  a merged PR is the approval and nothing unreviewed reaches a target.
- **macOS targets.** Tailscale SSH server needs the open-source `tailscaled`,
  not the App Store or standalone app. The MacBook Plex box will need that, or
  plain sshd with a key for `agent` instead. Not handled by the bootstrap
  script yet.
