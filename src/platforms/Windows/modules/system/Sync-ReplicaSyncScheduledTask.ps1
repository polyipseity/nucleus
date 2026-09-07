<#
.SYNOPSIS
  Ensure the daily replica sync scheduled task is converged.

.DESCRIPTION
  Task registration is delegated to DSC (system/scheduler-user.dsc.yml).
  This module verifies the script exists and provides cleanup when disabled.

.PARAMETER RepoRoot
  Absolute repository root path used to resolve scripts\cloud.ps1.

.PARAMETER Enabled
  Whether the scheduled task should exist. When false, the managed task is
  removed if present.

.EXAMPLE
  Sync-ReplicaSyncScheduledTask -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$true

.EXAMPLE
  Sync-ReplicaSyncScheduledTask -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$false

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    0 on success; 1 on error.
#>
function Sync-ReplicaSyncScheduledTask {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusReplicaSyncDaily"

  if (-not $Enabled) {
    # DSC handles task removal via scheduler-user.dsc.yml. The PowerShell
    # module only removes the task when the feature is explicitly disabled.
    # check-suppress:suppression_doc: probe -- task may not exist; $null check handles missing task.
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-NucleusInfo -CommandName 'replica-sync' "removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Task registration is handled by DSC (system/scheduler-user.dsc.yml).
  # This module verifies the script exists and warns if not provisioned.
  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $scriptPath = Join-Path -Path $resolvedRepoRoot -ChildPath "scripts\cloud.ps1"
  if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
    Write-NucleusWarning -CommandName 'replica-sync' "cloud sync script not found at '$scriptPath'."
    return
  }

  Write-NucleusInfo -CommandName 'replica-sync' "task registration delegated to DSC (scheduler-user.dsc.yml)"
}
