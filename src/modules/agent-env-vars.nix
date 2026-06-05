# modules/agent-env-vars.nix — AI agent session detection environment variables.
#
# Single source of truth for the set of environment variable names that AI
# coding agents set to identify their sessions.  shell.nix, pwsh.nix, and
# Sync-ShellProfile.ps1 (Windows) all use this list.  Keep additions and
# removals here, then update the consumers.
#
# Env var reference: https://docs.anthropic.com/en/docs/claude-code/overview
# (upstream tools list is fragmented; this is a curated union of well-known
#  agent identifiers)
{
  # Alphabetical list of env var names that AI coding agents set to identify
  # non-human sessions.
  agentEnvVarNames = [
    "AGENT"
    "AI_AGENT"
    "AUGMENT_AGENT"
    "CLAUDECODE"
    "CLAUDE_CODE"
    "CLINE_ACTIVE"
    "CODEX_SANDBOX"
    "CURSOR_AGENT"
    "GEMINI_CLI"
    "GOOSE_TERMINAL"
    "OPENCODE_CLIENT"
    "TRAE_AI_SHELL_ID"
    "VSCODE_AGENT"
  ];
  # POSIX filesystem marker path for Devin agent sessions.
  devinPosixPath = "/opt/.devin";
  # Windows filesystem marker path for Devin agent sessions.
  devinWindowsPath = "C:\\opt\\.devin";
}
