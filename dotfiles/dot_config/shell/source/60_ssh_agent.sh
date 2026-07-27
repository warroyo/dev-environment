[[ -o interactive ]] || return

# Linux/server only (excluded on macOS by .chezmoiignore.tmpl): launchd
# provides an agent on macOS, and AddKeysToAgent/UseKeychain in ~/.ssh/config
# handle key loading there.
#
# Maintain a STABLE SSH_AUTH_SOCK path so tmux panes and reattached sessions
# always reference the same socket. That path is a symlink we repoint at
# whichever live agent this login should use:
#
#   1. an agent forwarded from the client (`ssh -A`), preferred when present
#   2. otherwise a single shared local agent on a fixed path, started on demand
#
# Why this is needed: a forwarded socket lives at a per-connection
# /tmp/ssh-*/agent.* path that dies with the connection, but tmux panes
# outlive it. Without a stable indirection, every pane from an older
# connection points at a dead socket.
#
# Every ssh-add probe is wrapped in `timeout 2`. A forwarded socket whose SSH
# connection died (laptop slept, network roamed) still ACCEPTS connections but
# never answers — a bare `ssh-add -l` then blocks forever, hanging every new
# shell. ssh-add exits 2 when no agent is reachable; timeout exits 124; treat
# both as "unusable".

_agent_link="${XDG_RUNTIME_DIR:-$HOME/.ssh}/ssh-agent.socket"
mkdir -p "$(dirname "$_agent_link")" 2>/dev/null

# 1. Prefer an agent handed to this session. It's inherited when SSH_AUTH_SOCK
#    points somewhere other than our stable symlink, and it answers.
if [[ -n "${SSH_AUTH_SOCK:-}" && "$SSH_AUTH_SOCK" != "$_agent_link" ]]; then
  timeout 2 ssh-add -l >/dev/null 2>&1
  if [[ $? -lt 2 ]]; then
    ln -sfn "$SSH_AUTH_SOCK" "$_agent_link"
    export SSH_AUTH_SOCK="$_agent_link"
    unset _agent_link
    return
  fi
fi

# 2. No usable forwarded agent: use the stable path and (re)start a local agent
#    behind it if what it points at is dead or missing. flock serializes the
#    check-and-start so concurrent logins don't each spawn an agent or race on
#    the relink.
export SSH_AUTH_SOCK="$_agent_link"
timeout 2 ssh-add -l >/dev/null 2>&1
if [[ $? -ge 2 ]]; then
  flock "${_agent_link}.lock" sh -c '
    timeout 2 ssh-add -l >/dev/null 2>&1
    if [ $? -ge 2 ]; then
      rm -f "$1"
      ssh-agent -a "$1" >/dev/null 2>&1
    fi
  ' _ "$_agent_link" 2>/dev/null
fi
unset _agent_link

# Probe the agent without risking a hang.
alias ssh-check='timeout 2 ssh-add -l'
