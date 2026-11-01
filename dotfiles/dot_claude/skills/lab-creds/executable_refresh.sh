#!/usr/bin/env bash
# Log the vcf CLI back in to the lab with the credentials in ~/.lab.env, then
# check that kubectl works. Prints no secret.
#
#   refresh.sh                 both contexts, each only when its session has expired
#   refresh.sh <supervisor>    the Supervisor only ($SUPERVISOR_CONTEXT)
#   refresh.sh <vcfa>          VCF Automation only ($VCFA_CONTEXT)
#   refresh.sh --force [name]  refresh even when the session still works
set -uo pipefail

env_file="${LAB_ENV:-$HOME/.lab.env}"
[ -r "$env_file" ] || { echo "missing $env_file" >&2; exit 1; }
set -a; . "$env_file"; set +a

force=no
[ "${1:-}" = "--force" ] && { force=yes; shift; }
[ $# -gt 0 ] && contexts=("$@") || contexts=("$SUPERVISOR_CONTEXT" "$VCFA_CONTEXT")

# /apis needs a login but no role, so it works in a context that cannot list
# namespaces.
check() { kubectl --context "$1" --request-timeout=10s get --raw /apis >/dev/null 2>&1; }

# The vcf CLI reads the secret from a variable in place of its prompt. Which
# variable depends on the kind of context.
login() {
  case "$1" in
    "$SUPERVISOR_CONTEXT") VCF_CLI_VSPHERE_PASSWORD="$VC_PASSWORD" vcf context refresh "$1" ;;
    "$VCFA_CONTEXT")       VCF_CLI_VCFA_API_TOKEN="$VCFA_TENANT_API_TOKEN" vcf context refresh "$1" ;;
    *) echo "$1: not a context this script knows" >&2; return 1 ;;
  esac </dev/null >/dev/null 2>&1
}

failed=0
for context in "${contexts[@]}"; do
  if [ "$force" = no ] && check "$context"; then
    echo "$context: session still valid"
  elif login "$context" && check "$context"; then
    echo "$context: refreshed"
  else
    echo "$context: refresh failed. Run 'vcf context refresh $context' by hand to see why." >&2
    failed=1
  fi
done
exit $failed
