<#
.SYNOPSIS
  Ensure discord-music-rpc startup task is converged on Windows.

.DESCRIPTION
  Manages the discord-music-rpc tray application lifecycle for each managed
  user:
    1. Creates or removes a logon scheduled task that starts the Rich Presence
       tray application in the background.

  The config.yaml symlink is managed by apply.ps1 (same pattern as LiteLLM),
  pointing directly into the repo tree so edits take effect immediately.
  The package must be installed separately (e.g. via `uv tool install`).

.PARAMETER Enabled
  True applies the config and registers the startup task.  False removes the
  startup task and warns that the config remains on disk.  The config symlink
  is managed by apply.ps1 (same as LiteLLM).

.EXAMPLE
  Sync-DiscordMusicRPC -Enabled:$true

.EXAMPLE
  Sync-DiscordMusicRPC -Enabled:$false

.NOTES
  Environment variables:
    (none)

  Exit codes:
    0 on success; 1 on error.
#>
function Sync-DiscordMusicRPC {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusDiscordMusicRPC"
  $logDir = Get-NucleusLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "discord-music-rpc"
  $null = New-Item -Path $serviceLogDir -ItemType Directory -Force
  $logFile = Join-Path -Path $serviceLogDir -ChildPath "combined.log"

  if (-not $Enabled) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "discord-music-rpc: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Config symlink is managed by apply.ps1 (same as LiteLLM).  Ensure log
  # directory exists.
  $null = New-Item -Path $logDir -ItemType Directory -Force

  # Find the discord-music-rpc binary (installed via uv tool install or pip).
  $discordMusicRpcCmd = Get-Command -Name "discord-music-rpc" -ErrorAction SilentlyContinue
  if ($null -eq $discordMusicRpcCmd) {
    Write-Output "discord-music-rpc: binary not found in PATH; install via 'uv tool install git+https://github.com/polyipseity/ext.discord-music-rpc'"
    return
  }
  $discordMusicRpcBin = $discordMusicRpcCmd.Source

  # Register a logon scheduled task that starts the tray app in a hidden
  # PowerShell window so no console window appears at startup.
  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-WindowStyle Hidden -NoLogo -ExecutionPolicy Bypass -NoProfile -Command `"& '$discordMusicRpcBin' *>> '$logFile'`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

  $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
  Write-Output "discord-music-rpc: registered scheduled task '$taskName'"
}
