# Deployed only on machines where Claude Code must never be INSTALLED — the
# work laptop, and any machine with an unrecognised role (see
# .chezmoiignore.tmpl). Those machines still get claude-attach/claude-env,
# which only SSH to the server; this guards the one path that would put Claude
# Code on the local disk without anyone choosing to.
#
# Unguarded by `[[ -o interactive ]]` on purpose: VS Code spawns its integrated
# terminal non-interactively, which is exactly the case this defends against.
#
# Belt-and-braces with "claude-code.autoInstallIdeExtension": false in the
# managed VS Code settings.json: this machine must never auto-install the
# Claude Code IDE extension. See docs/client-work-setup.md.
export CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1
