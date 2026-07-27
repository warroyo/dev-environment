[[ -o interactive ]] || return

# zsh plugin loader. Package layouts differ between Homebrew and apt, so probe
# both. Order matters: zsh-syntax-highlighting must be sourced LAST or it won't
# wrap the widgets the other plugins install.
_zsh_plugin() {
  local name="$1" f
  local candidates=(
    "/usr/share/${name}/${name}.zsh"
    "/usr/share/zsh/plugins/${name}/${name}.zsh"
  )
  if command -v brew >/dev/null 2>&1; then
    candidates+=("$(brew --prefix 2>/dev/null)/share/${name}/${name}.zsh")
  fi
  for f in "${candidates[@]}"; do
    [[ -r "$f" ]] && { source "$f"; return 0; }
  done
  return 1
}

_zsh_plugin zsh-autosuggestions
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'   # dim the ghost text

# starship: one binary, one config (~/.config/starship.toml), identical prompt
# on the server and both Macs. Without it zsh falls back to its bare built-in
# prompt (`hostname%`) — no cwd, no colours, no git info.
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
else
  autoload -Uz colors && colors
  PROMPT='%F{cyan}%~%f %F{green}❯%f '
fi

# Must be last.
_zsh_plugin zsh-syntax-highlighting
