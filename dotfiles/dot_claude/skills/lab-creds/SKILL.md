---
name: lab-creds
description: Refresh or read Will's lab credentials (the gpu.set.lab lab: vCenter vc01, the sup-gpu Supervisor, VCF Automation at auto.gpu.set.lab). Use as soon as kubectl against a sup-gpu or vcfa context answers "You must be logged in to the server" or "the server has asked for the client to provide credentials", when `vcf context use` or `vcf context refresh` asks for a password, when a vCenter or VCF Automation API call needs a login, or when asked to "refresh the lab creds", "log back in to the supervisor", or "where is the vCenter password". Use it before asking Will to log in by hand. Not for GitHub auth, and not for a repo's own secrets such as Terraform state tokens or deploy keys.
---

The lab logins are in `~/.lab.env`, mode 600, outside every repo. One file,
so no repo has to be found first.

## Rules

- Never print a value from the file. No `cat`, no `echo $VC_PASSWORD`, no
  `env`, no `set -x` while it is loaded. To look at the file, redact:
  `sed -E 's/(PASSWORD|TOKEN)=.*/\1=<redacted>/' ~/.lab.env`.
- Never copy a value into a repo, a commit, a doc, a memory, or a log entry.
  Refer to the variable name.
- Load it only in the command that needs it. Shell state does not carry
  between Bash calls, so each command loads it again:
  `set -a; . ~/.lab.env; set +a; <command>`.
- Pass a password to curl with `-u "$VC_USER:$VC_PASSWORD"`, inside the same
  command, so that the expanded value is not in the command text.

## What is in it

| Variable | What it is |
|---|---|
| `VC_HOST`, `VC_USER`, `VC_PASSWORD` | vCenter. The same login works for the Supervisor and most of the lab. |
| `SUPERVISOR_CONTEXT`, `SUPERVISOR_ENDPOINT` | The vcf CLI and kubectl context `sup-gpu`, and its address. |
| `VCFA_URL`, `VCFA_USER`, `VCFA_ORG`, `VCFA_PASSWORD` | VCF Automation, the provider administrator in the `System` org. |
| `VCFA_CONTEXT`, `VCFA_TENANT_ORG`, `VCFA_TENANT_API_TOKEN` | VCF Automation, the tenant org `acme`: the vcf CLI and kubectl context `vcfa`, and the API token it logs in with. |

## A kubectl session expired

```sh
~/.claude/skills/lab-creds/refresh.sh
```

It checks `sup-gpu` and `vcfa`, and logs in again only to the one that has
expired. Name a context to do one only; `--force` refreshes a session that
still works. Then run the command that failed again.

It runs `vcf context refresh` with the secret in a variable that the vcf CLI
reads in place of its prompt:

| Context | Variable the vcf CLI reads | Value |
|---|---|---|
| `sup-gpu` | `VCF_CLI_VSPHERE_PASSWORD` | `VC_PASSWORD` |
| `vcfa` | `VCF_CLI_VCFA_API_TOKEN` | `VCFA_TENANT_API_TOKEN` |

Every `sup-gpu:<namespace>` context shares the `sup-gpu` login, and every
`vcfa:<namespace>:<project>` context shares the `vcfa` login, so one refresh
covers them all. The `vcfa` refresh also creates the contexts of namespaces
made since the last login. For the Supervisor, `vcf context use sup-gpu` with
the same variable set does that.

To test a session, use `kubectl --context <name> get --raw /apis`. In `vcfa`
the user cannot list namespaces, so `get ns` answers Forbidden with a session
that works.

## vCenter API

```sh
set -a; . ~/.lab.env; set +a
sid=$(curl -sk -u "$VC_USER:$VC_PASSWORD" -X POST "https://$VC_HOST/api/session" | tr -d '"')
curl -sk -H "vmware-api-session-id: $sid" "https://$VC_HOST/api/vcenter/namespaces/instances"
curl -sk -X DELETE -H "vmware-api-session-id: $sid" "https://$VC_HOST/api/session"
```

Supervisor Namespaces made in vCenter are under
`/api/vcenter/namespaces/instances`. Delete the session when done.

## VCF Automation API

```sh
set -a; . ~/.lab.env; set +a
curl -sk -D - -o /dev/null -X POST -H 'Accept: application/json;version=40.0' \
  -u "$VCFA_USER@$VCFA_ORG:$VCFA_PASSWORD" "$VCFA_URL/cloudapi/1.0.0/sessions/provider"
```

The bearer token is the response header `x-vmware-vcloud-access-token`. Do
not print the headers; read that one into a variable.

For the tenant org, trade the API token for an access token:

```sh
set -a; . ~/.lab.env; set +a
access=$(curl -sk -X POST "$VCFA_URL/tm/oauth/tenant/$VCFA_TENANT_ORG/token" \
  -d grant_type=refresh_token --data-urlencode "refresh_token=$VCFA_TENANT_API_TOKEN" | jq -r .access_token)
```

## When a login is refused

The file is a copy. The sources are:

- `VC_*`: `~/workspace/ansible-supervisor-service/.env`
- `VCFA_PASSWORD`: `vcfa_password` in
  `~/workspace/goad/the-goad/terraform/cloud-admin/terraform.tfvars`
- `VCFA_TENANT_API_TOKEN`: `TF_VAR_vcfa_refresh_token` in
  `~/workspace/argocd-scaffolding/.env`

If the source has a newer value, tell Will, then copy it into `~/.lab.env`
with a script that reads the one file and writes the other, so that the
value is never in a command or in its output. If the source fails too, the
password changed in the lab: ask Will.

To add a credential, add a variable to `~/.lab.env` and a row to the table
above.
