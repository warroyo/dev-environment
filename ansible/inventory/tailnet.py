#!/usr/bin/env python3
"""Ansible inventory built from the tailnet, the same source lab-ssh-config uses.

Every peer tagged tag:<group> lands in group <group> (tag:lab -> lab,
tag:inference -> inference). Each host connects through its <name>-admin ssh
alias, so no hostname or username is committed to this repo.
"""
import json
import subprocess
import sys

if len(sys.argv) > 1 and sys.argv[1] == "--host":
    print("{}")
    sys.exit(0)

status = json.loads(subprocess.run(
    ["tailscale", "status", "--json"], check=True, capture_output=True, text=True
).stdout)

inventory = {"_meta": {"hostvars": {}}}
for peer in (status.get("Peer") or {}).values():
    tags = peer.get("Tags") or []
    if not tags:
        continue
    name = peer["DNSName"].split(".")[0]
    inventory["_meta"]["hostvars"][name] = {"ansible_host": f"{name}-admin"}
    for tag in tags:
        group = tag.removeprefix("tag:").replace("-", "_")
        inventory.setdefault(group, {"hosts": []})["hosts"].append(name)

json.dump(inventory, sys.stdout, indent=2)
