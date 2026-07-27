#!/usr/bin/env bash
# Homebrew install helpers shared by the two macOS bootstrap scripts.
#
# The important thing these do that a plain `brew list` check does not: detect
# software that is already installed WITHOUT Homebrew. `brew list --cask
# visual-studio-code` returns false when VS Code was installed by dragging it
# to /Applications, and `brew install --cask` then ABORTS with "It seems there
# is already an App at ...", which under `set -e` kills the whole bootstrap
# before it reaches chezmoi.

# ensure_formula <formula> [binary-that-proves-it-is-already-present]
ensure_formula() {
  local formula="$1" probe="${2:-}"

  if brew list --formula "$formula" >/dev/null 2>&1; then
    echo "  $formula already installed (brew)"
    return 0
  fi

  # Already present some other way — don't install a second copy.
  if [ -n "$probe" ] && command -v "$probe" >/dev/null 2>&1; then
    echo "  $formula already present as '$probe' ($(command -v "$probe")) — skipping brew install"
    return 0
  fi

  echo "  installing $formula"
  brew install "$formula"
}

# ensure_cask <cask> <app-name.app>
#
# Skips when the .app already exists, whoever installed it. Homebrew can take
# over an existing install with `brew install --cask --adopt <cask>`, but that
# is left as a deliberate choice rather than something a bootstrap script does
# to an app you installed yourself.
ensure_cask() {
  local cask="$1" app="${2:-}"

  if brew list --cask "$cask" >/dev/null 2>&1; then
    echo "  $cask already installed (brew)"
    return 0
  fi

  if [ -n "$app" ]; then
    for dir in "/Applications" "$HOME/Applications"; do
      if [ -d "${dir}/${app}" ]; then
        echo "  ${app} already installed at ${dir} (not via brew) — skipping"
        echo "    to let brew manage it instead: brew install --cask --adopt ${cask}"
        return 0
      fi
    done
  fi

  echo "  installing $cask"
  brew install --cask "$cask"
}
