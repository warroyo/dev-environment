[[ -o interactive ]] || return

# Modern CLI tool replacements. See docs/terminal-and-editor-defaults.md.
#
# NOTE: `find` and `grep` are deliberately NOT aliased to fd/rg. Their flag
# syntax is incompatible (`find . -name x`, `grep -r` both error under the
# replacements), which breaks muscle memory and copy-pasted commands in ways
# that are annoying to diagnose. Use `fd` and `rg` by name.
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first'
  alias ll='eza -la --group-directories-first'
  alias lt='eza --tree --level=2'
fi
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never'

alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --graph --oneline --decorate'

alias reload='exec zsh'
alias vhere='vscode-here'
