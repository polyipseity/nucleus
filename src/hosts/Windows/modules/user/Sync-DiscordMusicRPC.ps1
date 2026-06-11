<#
.SYNOPSIS
  Ensure discord-music-rpc config and startup task are converged on Windows.

.DESCRIPTION
  Manages the discord-music-rpc tray application lifecycle for each managed
  user:
    1. Writes the declarative config.yaml (all default values explicit) to the
       app's config directory ($env:LOCALAPPDATA\discord-music-rpc\)
    2. Creates or removes a logon scheduled task that starts the Rich Presence
       tray application in the background.

  The package must be installed separately (for example via `uv tool install`).

.PARAMETER Enabled
  True applies the config and registers the startup task.  False removes the
  startup task and warns that the config remains on disk.

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
  $configDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "discord-music-rpc"
  $configPath = Join-Path -Path $configDir -ChildPath "config.yaml"
  $logDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "nucleus\logs"
  $logFile = Join-Path -Path $logDir -ChildPath "discord-music-rpc.log"

  if (-not $Enabled) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "discord-music-rpc: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Write config file with all default values explicit.
  $null = New-Item -Path $configDir -ItemType Directory -Force
  $configContent = @"
discord:
  status_type: artist
  show_progress: true
  show_source_logo: true
  show_urls: true
  show_ad: true
spotify:
  enabled: false
  client_id: null
  client_secret: null
  redirect_uri: http://localhost:8888/callback
lastfm:
  enabled: false
  username: null
  api_key: null
plex:
  enabled: false
  server_url: null
  token: null
  libraries: []
soundcloud:
  enabled: false
youtube:
  enabled: false
"@
  Set-Content -Path $configPath -Value $configContent -NoNewline
  Write-Output "discord-music-rpc: wrote config to '$configPath'"

  # Ensure log directory exists.
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
