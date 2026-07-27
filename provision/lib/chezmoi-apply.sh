#!/usr/bin/env bash
# Shared by all three bootstrap scripts. Source it, then call:
#
#     apply_dotfiles <role> <repo-root>
#
# where <role> is server | personal | work. Idempotent.

# Write the machine's role into chezmoi's own config, OUTSIDE the repo. This
# replaced hostname matching, which was both identifying (hostnames had to be
# committed) and fragile — chezmoi strips the domain from .chezmoi.hostname and
# macOS reports mixed case, which silently broke matching twice.
#
# The file is fully derived, so rewriting it every run is safe and keeps it
# correct if the repo moves. User-specific settings belong in ~/.zsh.local,
# ~/.gitconfig.local and ~/.secrets/ — not here.
write_chezmoi_config() {
  local role="$1" repo_root="$2"
  local cfg="$HOME/.config/chezmoi/chezmoi.toml"
  mkdir -p "$(dirname "$cfg")"
  cat >"$cfg" <<EOF
# Managed by dev-environment/provision — do not edit by hand.
# Machine-specific overrides belong in ~/.zsh.local, ~/.gitconfig.local
# and ~/.secrets/.
sourceDir = "${repo_root}/dotfiles"

[data]
  role = "${role}"
EOF
}

# Git identity is deliberately not in the repo (it is both machine-specific and
# identifying). Seed ~/.gitconfig.local from whatever is already configured on
# this machine, so an existing identity survives chezmoi replacing ~/.gitconfig.
# Never overwrites an existing ~/.gitconfig.local.
seed_gitconfig_local() {
  local target="$HOME/.gitconfig.local"
  [ -f "$target" ] && return 0

  local name email
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"

  if [ -n "$name" ] || [ -n "$email" ]; then
    cat >"$target" <<EOF
# Git identity — kept out of the dotfiles repo on purpose.
# Migrated from this machine's existing global git config.
[user]
    name = ${name}
    email = ${email}
EOF
    echo "  seeded ~/.gitconfig.local from existing git config (${email:-no email})"
  else
    cat >"$target" <<'EOF'
# Git identity — kept out of the dotfiles repo on purpose.
# FILL THIS IN, or commits will fail with "unable to auto-detect email address".
#
# Consider a dedicated alias rather than your primary address: it keeps your
# real mailbox out of every public commit while staying attributable.
[user]
    name =
    email =
EOF
    echo "  WARNING: no git identity found. Fill in ~/.gitconfig.local before committing."
  fi
}

# ssh config Include target must exist to be useful; ssh ignores it when
# missing, so this is purely so there's an obvious place to put local hosts.
seed_ssh_config_local() {
  local target="$HOME/.ssh/config.local"
  [ -f "$target" ] && return 0
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  cat >"$target" <<'EOF'
# Machine-specific SSH config — never committed. Included FIRST by
# ~/.ssh/config, and ssh uses the first value it sees for each keyword, so
# anything here overrides the managed config.
#
# The server's login name goes here rather than in the repo:
#   Host claude-server
#     User your-login-name
#
# On the work laptop the managed config has no `Host claude-server` block at
# all (that one points at the tailnet name, which does not resolve there), so
# add the whole entry here for claude-attach/claude-env to work:
#   Host claude-server
#     HostName 192.0.2.10        # the server's LAN IP, over the OpenVPN path
#     User your-login-name
EOF
  chmod 600 "$target"
}

apply_dotfiles() {
  local role="$1" repo_root="$2"
  echo
  echo "==> Applying dotfiles (role: ${role})"
  seed_gitconfig_local
  seed_ssh_config_local
  write_chezmoi_config "$role" "$repo_root"

  # The VS Code settings are force-applied first, on their own. Machines
  # provisioned before the settings file switched from being symlinked to being
  # copied have VS Code's own writes sitting in chezmoi's target, so a plain
  # apply stops and asks:
  #
  #   .config/vscode/settings.json has changed since chezmoi last wrote it?
  #   > diff/overwrite/all-overwrite/skip/quit
  #
  # and a bootstrap script has no answer for that. The recorded drift does not
  # clear itself either — anything but "overwrite" leaves it exactly as it was,
  # so the question comes back on every run until someone overwrites. The repo
  # is the source of truth for editor settings, so overwrite without asking.
  #
  # Once run_onchange_after_install-vscode-settings.sh has converted the
  # symlink into a copy, VS Code stops writing to this file at all and the flag
  # never has anything to overwrite. Kept as the migration path for the other
  # machines, and as a guard against the prompt ever blocking a run again.
  chezmoi apply --force "$HOME/.config/vscode/settings.json"

  # Everything else keeps the default prompt-on-drift behaviour: being asked
  # about a file something else has edited is the useful case, not this one.
  # sourceDir and role both come from the config written above, so no flags.
  chezmoi apply
  echo "==> Verifying role exclusions"
  chezmoi ignored | sed 's/^/  excluded: /' || true
}
