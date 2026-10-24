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
  - your own account (named in the policy's check rule): has sudo, and needs a Tailscale **check**. The first
    connection prints a login URL and waits. Opening it is the approval, and
    it holds for 12 hours.
- **Targets are tagged.** A tag takes the machine out of your ownership, so it
  cannot start connections into the tailnet. Only the SSH rules let anyone in.
- **The LAN stays a fallback.** sshd still serves the LAN, keys only, for when
  Tailscale is down.

The pieces:

| File | Does |
|---|---|
| [`policy/tailnet.hujson`](../policy/tailnet.hujson) | Tags and SSH rules. Pasted into the admin console by hand |
| [`provision/lab-target-bootstrap.sh`](../provision/lab-target-bootstrap.sh) | Run once per target: Tailscale SSH plus tags, the `agent` account, sshd keys-only |
| `lab-ssh-config` ([source](../dotfiles/dot_local/bin/executable_lab-ssh-config)) | Run on the server: writes the `<target>` and `<target>-admin` aliases from the tailnet |

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

## Tightening later

- **Make a target API-only.** Remove `tag:lab` and keep `tag:inference`. The
  SSH rules stop matching it, and the policy can then grant the API ports
  alone. The planned end state for the model server.
- **Let `agent` restart one system service.** Add a sudoers drop-in on the
  target naming that exact command, for example
  `agent ALL=(root) NOPASSWD: /usr/bin/systemctl restart gufo`. Never a
  wildcard.
- **macOS targets.** Tailscale SSH server needs the open-source `tailscaled`,
  not the App Store or standalone app. The MacBook Plex box will need that, or
  plain sshd with a key for `agent` instead. Not handled by the bootstrap
  script yet.
