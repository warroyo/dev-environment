[[ -o interactive ]] || return

# fzf shell integration. Paths differ by platform: Homebrew on macOS,
# /usr/share/doc on Debian/Ubuntu, plus fzf's own ~/.fzf.zsh if installed
# from git.
if [[ -r "$HOME/.fzf.zsh" ]]; then
  source "$HOME/.fzf.zsh"
elif command -v fzf >/dev/null 2>&1 && fzf --zsh >/dev/null 2>&1; then
  # fzf >= 0.48 ships its own integration; preferred when available.
  source <(fzf --zsh)
else
  for _d in \
    "$(command -v brew >/dev/null 2>&1 && brew --prefix 2>/dev/null)/opt/fzf/shell" \
    /usr/share/doc/fzf/examples \
    /usr/share/fzf
  do
    [[ -r "$_d/completion.zsh"   ]] && source "$_d/completion.zsh"
    [[ -r "$_d/key-bindings.zsh" ]] && source "$_d/key-bindings.zsh" && break
  done
  unset _d
fi

# Use fd for fzf's file walk when present: respects .gitignore and is much
# faster on large trees.
if command -v fd >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
fi
