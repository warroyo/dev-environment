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

# macOS: the Tailscale GUI app bundles the `tailscale` CLI but doesn't put it
# on PATH, so `tailscale status` is "command not found" even with the app
# running. The Homebrew formula would provide it, but installing that alongside
# the app gives you two competing daemons — so point at the app's copy instead.
if [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
  alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi
