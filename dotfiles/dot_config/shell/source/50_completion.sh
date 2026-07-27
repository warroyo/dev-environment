[[ -o interactive ]] || return

autoload -Uz compinit

# compinit's security audit stats every directory in fpath on every shell
# start, which is slow. Run the full check at most once a day and use the
# cached dump otherwise.
_zcompdump="${ZDOTDIR:-$HOME}/.zcompdump"
if [[ -n ${_zcompdump}(#qN.mh+24) ]]; then
  compinit -d "$_zcompdump"
else
  compinit -C -d "$_zcompdump"
fi
unset _zcompdump

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' list-colors ''
