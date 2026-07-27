# Deployed only on machines that are NOT part of the Claude Code layer — the
# work laptop, and any machine with an unrecognised role (see
# .chezmoiignore.tmpl). Unguarded on purpose: VS Code spawns its integrated
# terminal non-interactively, which is exactly the case this defends against.
#
# Belt-and-braces with "claude-code.autoInstallIdeExtension": false in the
# managed VS Code settings.json: this machine must never auto-install the
# Claude Code IDE extension. See docs/client-work-setup.md.
export CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1
