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
