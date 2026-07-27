# Terminal + locale basics. Unguarded: affects non-interactive output too.

# UTF-8 everywhere. Without this, the prompt's glyphs and anything drawing box
# characters (tmux, fzf) render as mojibake over SSH when the client forwards
# an empty or C locale.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-$LANG}"

# Tell programs the terminal really does support 24-bit colour. SSH does not
# forward COLORTERM, and inside tmux $TERM becomes tmux-256color, so without
# this many tools quietly downgrade to 256 colours.
export COLORTERM="${COLORTERM:-truecolor}"
