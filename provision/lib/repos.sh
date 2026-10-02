#!/usr/bin/env bash
# Working repos that the server is expected to have on disk. Source it, then:
#
#     ensure_repo <url> <dest>     clone if missing, otherwise leave alone
#     ensure_work_repos            the actual list (server)
#     ensure_vault_repo            the vault alone (both Macs)
#
# ensure_work_repos is SERVER ONLY, for the same reason the rest of the Claude
# Code layer is server-only: this is the machine that runs the CLI, so it is
# the machine that needs the blog checkout and the prose skill. The two client
# bootstraps source this file for ensure_vault_repo and nothing else — the Macs
# are where Obsidian opens the vault.
#
# The vault used to be server-only too, back when it was just the dev log. It
# is on the work laptop deliberately now: it holds personal lab notes, nothing
# customer-related, and it is plain markdown, not Claude Code.
#
# Why this exists at all: ~/workspace was previously just a directory the herdr
# session started in, and whatever repos lived under it were cloned by hand on
# each machine. That made the blog writing flow un-reproducible — /post-ideas
# reads ~/second-brain and claude-telegram-bot opens dirs under ~/workspace, so both
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
  # status` reports "Git operations protocol: https", and the existing ~/second-brain
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

# update_repo_if_clean <dest>
#
# The one exception to ensure_repo's "never touch an existing checkout" rule,
# for repos this machine CONSUMES rather than works in — a skill, where a stale
# copy silently means Claude Code writes against old rules.
#
# Still refuses anything that could cost work: it only fast-forwards, only on a
# clean tree, and only when the checked-out branch is the remote's default. A
# feature branch or an uncommitted edit means someone is working on the skill
# here, so it is left exactly as it is.
#
# Never fatal, like ensure_repo. GIT_TERMINAL_PROMPT=0 so a private repo with no
# credentials fails fast instead of hanging the bootstrap on a password prompt.
update_repo_if_clean() {
  local dest="$1" name branch default
  name="$(basename "$dest")"
  [ -d "$dest/.git" ] || return 0

  if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
    echo "  ${name} has local changes — not pulling"
    return 0
  fi

  branch="$(git -C "$dest" symbolic-ref --short -q HEAD || true)"
  default="$(git -C "$dest" symbolic-ref --short -q refs/remotes/origin/HEAD || true)"
  if [ -z "$branch" ] || [ "origin/${branch}" != "${default:-origin/main}" ]; then
    echo "  ${name} is not on its default branch (${branch:-detached}) — not pulling"
    return 0
  fi

  if GIT_TERMINAL_PROMPT=0 git -C "$dest" pull -q --ff-only 2>/dev/null; then
    echo "  ${name} up to date ($(git -C "$dest" rev-parse --short HEAD))"
  else
    echo "  WARNING: could not fast-forward ${name} — no credentials, offline," >&2
    echo "           or local commits that diverge from origin" >&2
  fi
  return 0
}

# link_skill <repo-dir> <skill-name>
#
# Point ~/.claude/skills/<skill-name> at a checkout whose root is the skill
# (SKILL.md at the top level). A symlink rather than cloning straight into
# ~/.claude/skills, so the checkout lives under ~/workspace where it can be
# opened and edited like any other repo — including from the phone with
# /cc_open — and edits are live in Claude Code without a copy step.
#
# Replaces a symlink that points elsewhere; never replaces a real directory.
link_skill() {
  local src="$1" skill="$2" link
  link="$HOME/.claude/skills/${skill}"

  if [ ! -f "$src/SKILL.md" ]; then
    echo "  WARNING: ${src}/SKILL.md not found — not linking skill ${skill}" >&2
    return 0
  fi

  mkdir -p "$HOME/.claude/skills"
  if [ -L "$link" ]; then
    if [ "$(readlink "$link")" = "$src" ]; then
      echo "  skill ${skill} already linked"
      return 0
    fi
    ln -sfn "$src" "$link"
    echo "  re-pointed skill ${skill} at ${src}"
  elif [ -e "$link" ]; then
    echo "  WARNING: ${link} exists and is not a symlink — leaving it alone" >&2
  else
    ln -s "$src" "$link"
    echo "  linked skill ${skill} -> ${src}"
  fi
  return 0
}

# ensure_vault_repo
#
# The second-brain vault, at the same path on all three machines. One function
# so the server (which writes dev-log entries into it) and the two Macs (which
# open it in Obsidian) cannot drift apart on the slug or the location —
# DEV_LOG_PITCHES in .zshenv and the /post-* commands assume ~/second-brain.
#
# Clone-if-missing only, like every ensure_repo call. Keeping the two checkouts
# in step is done by the things that write to them: dev-log-entry rebases and
# pushes on the server, the Obsidian Git plugin does on each Mac.
ensure_vault_repo() {
  ensure_repo warroyo/second-brain "$HOME/second-brain"
}

# link_bin <file> <name>
#
# Put an executable that lives in a checkout on PATH as ~/.local/bin/<name>.
# The same contract as link_skill: replaces a symlink that points elsewhere,
# never replaces a real file. A real file at that path is most likely the copy
# chezmoi used to deploy before the script moved into the vault; chezmoi has
# stopped managing it but does not delete it, so say how to clear it.
link_bin() {
  local src="$1" name="$2" link
  link="$HOME/.local/bin/${name}"

  if [ ! -x "$src" ]; then
    echo "  WARNING: ${src} not found or not executable — not linking ${name}" >&2
    return 0
  fi

  mkdir -p "$HOME/.local/bin"
  if [ -L "$link" ]; then
    if [ "$(readlink "$link")" = "$src" ]; then
      echo "  ${name} already linked"
      return 0
    fi
    ln -sfn "$src" "$link"
    echo "  re-pointed ${name} at ${src}"
  elif [ -e "$link" ]; then
    echo "  WARNING: ${link} exists and is not a symlink — leaving it alone." >&2
    echo "           If it is the old chezmoi-managed copy: rm ${link}, then re-run." >&2
  else
    ln -s "$src" "$link"
    echo "  linked ${name} -> ${src}"
  fi
  return 0
}

# link_vault_tooling
#
# The vault carries its own Claude Code tooling under .tools/, so the scripts
# that enforce its layout and the README that describes it change in one
# commit:
#
#   .tools/skills/log-session    /log-session — writes a dev-log entry
#   .tools/skills/second-brain   notes in topics/, notes/ and inbox/
#   .tools/bin/dev-log-entry     the writer behind the first
#   .tools/bin/vault-note        the writer and linter behind the second
#
# This makes them available to every Claude Code session on the machine, not
# just one started inside the vault: skills into ~/.claude/skills, scripts onto
# PATH. .tools/ rather than .claude/ in the vault on purpose — a session that
# IS started inside the vault would otherwise load each skill twice, once as a
# project skill and once through these links.
#
# SERVER ONLY, which is now the whole of the role gating for these four: the
# vault is cloned on the Macs too, files and all, but nothing links them there,
# and there is no Claude Code there to run them.
#
# Symlinks into the checkout, so a tooling change pushed from any machine is
# live here at the next pull with no bootstrap re-run. If the clone above
# failed (no GitHub credentials yet) each call warns and returns; re-running
# the bootstrap after `gh auth login` lands them.
link_vault_tooling() {
  local tools="$HOME/second-brain/.tools"
  link_skill "$tools/skills/log-session"  log-session
  link_skill "$tools/skills/second-brain" second-brain
  link_bin   "$tools/bin/dev-log-entry"   dev-log-entry
  link_bin   "$tools/bin/vault-note"      vault-note
}

# The list:
#
#   second-brain   PRIVATE. The Obsidian vault. Its entries/ folder is the dev
#                  log (raw session material) and pitches/ is the staging area
#                  that /post-ideas and /post-brief read. Lives at
#                  ~/second-brain, not under ~/workspace, on every machine that
#                  has it — see ensure_vault_repo. It also carries the
#                  /log-session and second-brain skills and their scripts,
#                  linked into place by link_vault_tooling.
#   warroyo-blog   PUBLIC. The Hugo site. Must live under ~/workspace
#                  specifically, because that is where claude-telegram-bot
#                  resolves /cc_open <dir> — the phone entry point to the flow.
#   will-prose     PRIVATE. The Claude Code skill for writing in the blog's
#                  voice. Unlike the other two it is pulled on every run (see
#                  update_repo_if_clean) and linked into ~/.claude/skills.
#
# A note on the failure you will actually hit: this bootstrap sets up no GitHub
# credentials of its own — there is no `gh auth login` step, and private_dot_ssh/
# writes SSH *config*, not keys. So on a genuinely fresh machine the PUBLIC blog
# clone still succeeds (https, no auth needed) and the PRIVATE second-brain clone does
# not. That is why ensure_repo warns instead of aborting: the script's documented
# model is that it is safe to run twice (see the ordering note in its header),
# and verify-server.sh is what reports a clone that never landed.
ensure_work_repos() {
  ensure_vault_repo
  link_vault_tooling
  ensure_repo warroyo/warroyo-blog "$HOME/workspace/warroyo-blog"

  ensure_repo warroyo/will-prose   "$HOME/workspace/will-prose"
  update_repo_if_clean             "$HOME/workspace/will-prose"
  link_skill                       "$HOME/workspace/will-prose" will-prose
}
