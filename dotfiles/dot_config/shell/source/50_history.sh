[[ -o interactive ]] || return

HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

setopt SHARE_HISTORY        # history shared live across concurrent shells —
                            # matters here: several tmux panes on one server
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE    # leading space keeps a command out of history
setopt HIST_REDUCE_BLANKS
setopt EXTENDED_HISTORY     # record timestamps
setopt HIST_VERIFY          # expand !! into the line for review, don't run it
