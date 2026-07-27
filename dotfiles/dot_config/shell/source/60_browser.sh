[[ -o interactive ]] || return

# Server-only (excluded elsewhere by .chezmoiignore.tmpl).
#
# A CLI tool that wants to open a URL (docs links, `gh auth login`, OAuth
# flows) can't launch a browser on a headless box. Print the URL instead:
# Ghostty renders http(s):// as a clickable link, so clicking it opens the
# browser on YOUR Mac. No reverse tunnel, no listener, no token.
#
# Only remap while we're the far end of an SSH session, so the box behaves
# normally if used directly (e.g. over the Comet Pro KVM console).
#
# This does not affect actual listening dev servers — VS Code Remote-SSH's
# automatic port forwarding already handles those.
if [[ -n "${SSH_CONNECTION:-}" || -n "${TMUX:-}" ]]; then
  export BROWSER=echo          # honored by xdg-open, python -m webbrowser, gh
  open() { printf '%s\n' "$1"; }
  alias xdg-open=open
fi
