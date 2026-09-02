#!/usr/bin/env bash
# Working repos that the server is expected to have on disk. Source it, then:
#
#     ensure_repo <url> <dest>     clone if missing, otherwise leave alone
#     ensure_work_repos            the actual list
#
# SERVER ONLY. Sourced by server-bootstrap.sh and by neither client script, for
# the same reason the rest of the Claude Code layer is server-only: this is the
# machine that runs the CLI, so it is the machine that needs the content. The
# work laptop must not end up with a clone of the dev log.
#
# Why this exists at all: ~/workspace was previously just a directory the herdr
# session started in, and whatever repos lived under it were cloned by hand on
# each machine. That made the blog writing flow un-reproducible — /post-ideas
# reads ~/dev-log and claude-telegram-bot opens dirs under ~/workspace, so both
# of those repos are load-bearing infrastructure, not incidental checkouts.

# ensure_repo <url> <dest>
#
# Clone <url> to <dest> if <dest> does not exist. If it does, do NOTHING — no
# fetch, no pull, no reset. This runs on a machine where the user is actively
# writing, and there is no version of "helpfully update your checkout" that is
# worth the chance of touching a dirty tree or moving a branch out from under an
# in-progress post. Keeping the repos current is the user's job; existing is
# this function's job.
#
# Never fatal. Returns 0 even when the clone fails, because of the auth problem
# described in ensure_work_repos below.
ensure_repo() {
  local slug="$1" dest="$2" name
  name="$(basename "$dest")"

  if [ -e "$dest" ]; then
    if [ -d "$dest/.git" ]; then
      echo "  ${name} already cloned"
    else
      # Something is in the way that is not a checkout. Do not delete it.
      echo "  WARNING: ${dest} exists but is not a git repo — leaving it alone" >&2
    fi
    return 0
  fi

  mkdir -p "$(dirname "$dest")"

  # HTTPS, not SSH, and gh first when it is available. This setup authenticates
  # to GitHub with a gh token in the keyring rather than an SSH key — `gh auth
  # status` reports "Git operations protocol: https", and the existing ~/dev-log
  # checkout has an https remote. An SSH URL here fails with "Permission denied
  # (publickey)" on a machine that is in fact perfectly well authenticated.
  #
  # `gh repo clone` is preferred because it applies that token itself. Plain git
  # is the fallback: it is enough for a PUBLIC repo with no credentials at all,
  # and picks up a credential helper when one is configured.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh repo clone "$slug" "$dest" -- -q && { echo "  cloned ${name}"; return 0; }
  else
    git clone -q "https://github.com/${slug}.git" "$dest" \
      && { echo "  cloned ${name}"; return 0; }
  fi

  rm -rf "$dest"
  echo "  WARNING: could not clone ${name} (${slug})" >&2
  echo "           Most likely this machine has no GitHub credentials yet." >&2
  echo "           Run 'gh auth login', then re-run this script." >&2
  return 0
}

# The list. Both are needed by the blog writing flow:
#
#   dev-log        PRIVATE. Raw session material and the pitches/ staging area
#                  that /post-ideas and /post-brief read.
#   warroyo-blog   PUBLIC. The Hugo site. Must live under ~/workspace
#                  specifically, because that is where claude-telegram-bot
#                  resolves /cc_open <dir> — the phone entry point to the flow.
#
# A note on the failure you will actually hit: this bootstrap sets up no GitHub
# credentials of its own — there is no `gh auth login` step, and private_dot_ssh/
# writes SSH *config*, not keys. So on a genuinely fresh machine the PUBLIC blog
# clone still succeeds (https, no auth needed) and the PRIVATE dev-log clone does
# not. That is why ensure_repo warns instead of aborting: the script's documented
# model is that it is safe to run twice (see the ordering note in its header),
# and verify-server.sh is what reports a clone that never landed.
ensure_work_repos() {
  ensure_repo warroyo/dev-log      "$HOME/dev-log"
  ensure_repo warroyo/warroyo-blog "$HOME/workspace/warroyo-blog"
}
