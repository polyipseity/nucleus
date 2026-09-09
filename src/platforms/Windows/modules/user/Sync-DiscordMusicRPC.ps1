<#
.SYNOPSIS
  Ensure discord-music-rpc config and startup task are converged on Windows.

.DESCRIPTION
  Manages the discord-music-rpc tray application lifecycle for each managed
  user:
    1. Deploys a writable config.yaml symlink into %LOCALAPPDATA%\discord-music-rpc\
       pointing into the repo tree so edits take effect immediately.
    2. Creates or removes a logon scheduled task that starts the Rich Presence
       tray application in the background.

  The package must be installed separately (e.g. via `uv tool install`).

.PARAMETER Enabled
  True applies the config symlink and registers the startup task.  False removes
  the startup task and warns that the config remains on disk.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository root.

.PARAMETER User
  Windows username for config overlay resolution.

.EXAMPLE
  Sync-DiscordMusicRPC -Enabled:$true -RepoRoot $repoRoot -User $sessionUser

.EXAMPLE
  Sync-DiscordMusicRPC -Enabled:$false -RepoRoot $repoRoot -User $sessionUser

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
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$User
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusDiscordMusicRPC"

  if (-not $Enabled) {
    # DSC handles task removal via scheduler-user.dsc.yml. The PowerShell
    # module only removes the task when the feature is explicitly disabled.
    # check-suppress:suppression_doc: probe -- task may not exist; $null check handles missing task.
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-NucleusInfo -CommandName 'discord-music-rpc' "removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Method-1 (writable) config symlink so repo edits take effect immediately.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  $configDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "discord-music-rpc"
  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  $null = New-Item -Path $configDir -ItemType Directory -Force
  $configPath = Join-Path -Path $configDir -ChildPath "config.yaml"
  $configSource = Resolve-UserConfigFile -User $User -ConfigName 'discord-music-rpc' -RelativePath 'config.yaml' -RepoRoot $RepoRoot
  if (Test-Path -Path $configPath) { Remove-Item -Path $configPath -Force }
  New-Item -Path $configPath -ItemType SymbolicLink -Target $configSource -Force > $null

  # Task registration is handled by DSC (system/scheduler-user.dsc.yml).
  # This module verifies the binary exists and warns if not provisioned.
  # check-suppress:suppression_doc: probe -- command may not be installed; $null check handles absence.
  $discordMusicRpcCmd = Get-Command -Name "discord-music-rpc" -ErrorAction SilentlyContinue
  if ($null -eq $discordMusicRpcCmd) {
    Write-NucleusInfo -CommandName 'discord-music-rpc' "binary not found in PATH; run nucleus-apply to converge the uv install (pinned via the uv section of src/lockfiles/lockfile.json — see Invoke-UvSetup)"
    return
  }

  Write-NucleusInfo -CommandName 'discord-music-rpc' "task registration delegated to DSC (scheduler-user.dsc.yml)"
}
