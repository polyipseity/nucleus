<#
.SYNOPSIS
  Agent host shell setup for Windows.

.DESCRIPTION
  Creates a wrapper script at %ProgramData%\nucleus\bin\ that exports
  NUCLEUS_AGENT_SESSION=1 and VSCODE_AGENT=1 before launching powershell.exe.

  Renamed to nucleus-agent-host-shell.ps1 for command-surface clarity. It
  remains a wrapper file (documented exception, not a nucleus app) because the
  consumer takes a path and cannot pass command arguments.

  The wrapper is referenced by terminal.integrated.agentHostProfile.windows
  in VS Code settings as %ProgramData%\nucleus\bin\nucleus-agent-host-shell.ps1.

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    This function does not emit exit codes.
#>
function Invoke-AgentHostShellSetup {
  <#
  .SYNOPSIS
    Converges the VS Code agent-host wrapper on Windows.

  .DESCRIPTION
    Writes %ProgramData%\nucleus\bin\nucleus-agent-host-shell.ps1 that
    exports agent detection environment variables and launches powershell.exe.
    The matching agentHostProfile.windows VS Code setting references this path.
    Documented exception: path-only consumer, not a nucleus app.
  #>

  # Create wrapper directory under ProgramData (nucleus-owned, not user HOME)
  $wrapperDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\bin"
  $null = New-Item -ItemType Directory -Path $wrapperDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

  # Write wrapper that sets agent detection vars and launches PowerShell
  $wrapperPath = Join-Path -Path $wrapperDir -ChildPath "nucleus-agent-host-shell.ps1"
  # check-suppress:embedded-content: exception 2 (trivial static content) -- .cmd wrapper under 10 lines
  @"
@echo off
SET NUCLEUS_AGENT_SESSION=1
SET VSCODE_AGENT=1
powershell.exe
"@ | Set-Content -Path $wrapperPath -NoNewline
  Write-NucleusInfo -CommandName 'nucleus-agent-host-shell' "wrote $wrapperPath"
}
