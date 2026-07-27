# Unguarded: scripts and remote commands need these too.
#
# Secrets never live in this repo. Drop one file per secret (or per service)
# into ~/.secrets/ and it gets sourced here — API tokens, per-machine
# credentials, anything you would not want in git.
#
#   mkdir -p ~/.secrets && chmod 700 ~/.secrets
#   echo 'export SOME_API_TOKEN=...' > ~/.secrets/some-service
#   chmod 600 ~/.secrets/some-service
#
# The directory is optional; nothing breaks if it doesn't exist.
if [[ -d "$HOME/.secrets" ]]; then
  for _s in "$HOME"/.secrets/*(N.); do
    source "$_s"
  done
  unset _s
fi
