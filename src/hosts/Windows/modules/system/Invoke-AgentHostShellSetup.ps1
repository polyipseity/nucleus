<#
.SYNOPSIS
  Agent host shell setup for Windows.

.DESCRIPTION
  Creates a batch wrapper script that exports NUCLEUS_AGENT_SESSION=1 and
  VSCODE_AGENT=1, then writes agent-host-config.json pointing to the wrapper
  for both stable and Insiders VS Code channels.

  This mirrors the POSIX agent-host-shell.nix approach: VS Code's
  AgentHostTerminalManager spawns agent shell sessions via node-pty directly,
  bypassing workbench terminal profiles. The wrapper ensures detection
  variables are present in every agent-spawned session.

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    This function does not emit exit codes.
#>
function Invoke-AgentHostShellSetup {
  <#
  .SYNOPSIS
    Converges the VS Code agent-host wrapper and configuration on Windows.

  .DESCRIPTION
    Writes %LOCALAPPDATA%\nucleus\agent-host-wrapper.cmd that exports agent
    detection environment variables and launches powershell.exe, then writes
    agent-host-config.json to VS Code globalStorage for both Code and
    Code - Insiders.

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      This function does not emit exit codes.
  #>

  # Create wrapper directory
  $wrapperDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "nucleus"
  $null = New-Item -ItemType Directory -Path $wrapperDir -Force

  # Write batch wrapper that sets agent detection vars and launches PowerShell
  $wrapperPath = Join-Path -Path $wrapperDir -ChildPath "agent-host-wrapper.cmd"
  @"
@echo off
SET NUCLEUS_AGENT_SESSION=1
SET VSCODE_AGENT=1
powershell.exe
"@ | Set-Content -Path $wrapperPath -NoNewline
  Write-Output "agent-host-shell: wrote $wrapperPath"

  # Build agent-host-config.json with escaped backslashes for JSON
  $escapedWrapper = $wrapperPath -replace '\\', '\\'
  $config = @{
    defaultShell = $escapedWrapper
    defaultPowerShellShell = $escapedWrapper
  }
  $jsonContent = ConvertTo-Json -InputObject $config

  # Write to both stable and Insiders globalStorage
  $base = $env:APPDATA
  foreach ($channel in @("Code", "Code - Insiders")) {
    $globalStorage = Join-Path -Path $base -ChildPath "$channel\User\globalStorage"
    $null = New-Item -ItemType Directory -Path $globalStorage -Force
    $configPath = Join-Path -Path $globalStorage -ChildPath "agent-host-config.json"
    $jsonContent | Set-Content -Path $configPath -NoNewline
    Write-Output "agent-host-shell: wrote $configPath"
  }
}
