# PATH beyond the minimum set in ~/.zshenv. Unguarded: scripts need it too.
# `typeset -U path` (set in .zshenv and .zshrc) keeps this idempotent, so
# re-sourcing never duplicates entries.

# Homebrew: Apple Silicon and Intel prefixes differ, and brew's own shellenv
# sets MANPATH/INFOPATH as well as PATH.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [[ -x "$_brew" ]]; then
    eval "$("$_brew" shellenv)"
    break
  fi
done
unset _brew

# Go, when installed.
[[ -d "$HOME/go/bin" ]] && path=("$HOME/go/bin" $path)
