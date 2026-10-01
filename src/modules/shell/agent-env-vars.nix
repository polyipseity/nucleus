# shell/agent-env-vars.nix - AI agent session detection environment variables.
#
# Canonical list of the variables coding agents set to mark a non-human
# session. shell.nix, pwsh.nix and Sync-ShellProfile.ps1 consume it; add or
# remove a name here and in those consumers.
# https://docs.anthropic.com/en/docs/claude-code/overview
{
  # Keep alphabetical.
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
    "NUCLEUS_AGENT_SESSION"
    "OPENCODE_CLIENT"
    "TRAE_AI_SHELL_ID"
    "VSCODE_AGENT"
  ];
  # Devin agent session marker path.
  devinPosixPath = "/opt/.devin";
  # Windows spelling of the same marker path.
  devinWindowsPath = "C:\\opt\\.devin";
}
