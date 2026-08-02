<#
.SYNOPSIS
  Agent host shell setup for Windows.

.DESCRIPTION
  Creates a batch wrapper script at USERPROFILE\.local\bin\ that exports
  NUCLEUS_AGENT_SESSION=1 and VSCODE_AGENT=1 before launching powershell.exe.

  The wrapper is referenced by terminal.integrated.agentHostProfile.windows
  in VS Code settings as ${userHome}\.local\bin\nucleus-agent-host-wrapper.cmd.

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
    Writes %USERPROFILE%\.local\bin\nucleus-agent-host-wrapper.cmd that
    exports agent detection environment variables and launches powershell.exe.
    The matching agentHostProfile.windows VS Code setting references this path.
  #>

  # Create wrapper directory under USERPROFILE
  $wrapperDir = Join-Path -Path $env:USERPROFILE -ChildPath ".local\bin"
  $null = New-Item -ItemType Directory -Path $wrapperDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

  # Write batch wrapper that sets agent detection vars and launches PowerShell
  $wrapperPath = Join-Path -Path $wrapperDir -ChildPath "nucleus-agent-host-wrapper.cmd"
  # check-suppress:embedded-content: exception 2 (trivial static content) -- .cmd wrapper under 10 lines
  @"
@echo off
SET NUCLEUS_AGENT_SESSION=1
SET VSCODE_AGENT=1
powershell.exe
"@ | Set-Content -Path $wrapperPath -NoNewline
  Write-Output "agent-host-shell: wrote $wrapperPath"
}
