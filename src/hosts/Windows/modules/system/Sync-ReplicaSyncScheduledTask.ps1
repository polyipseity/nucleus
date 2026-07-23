<#
.SYNOPSIS
  Ensure the daily replica sync scheduled task is converged.

.DESCRIPTION
  Registers (or updates) a per-user Task Scheduler entry that runs the managed
  `scripts\replica-sync.ps1` wrapper daily at 12:00 as a fallback backstop for
  missed post-apply runs. The task executes in interactive-user context so it
  has the same HOME/profile semantics as manual replica sync invocation.

.PARAMETER RepoRoot
  Absolute repository root path used to resolve scripts\replica-sync.ps1.

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
    # check-suppress:suppression_doc: probe — task may not exist; $null check handles missing task.
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "replica-sync: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $scriptPath = Join-Path -Path $resolvedRepoRoot -ChildPath "scripts\replica-sync.ps1"
  if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
    throw "replica-sync: scheduled task script not found at '$scriptPath'."
  }

  # check-suppress:suppression_doc: probe — pwsh may not be installed; throw handles absence.
  $pwshPath = (Get-Command -Name "pwsh" -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if ([string]::IsNullOrWhiteSpace($pwshPath)) {
    throw "replica-sync: pwsh not found; cannot register scheduled task '$taskName'."
  }

  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  # WHY interactive token: replica sync depends on user-scoped rclone config
  # and home-directory paths, so running in the logged-in user session avoids
  # machine-context path/credential mismatches.
  # WHY command wrapper first: daily fallback should follow the same user-facing
  # nucleus-replica-sync entrypoint as manual runs. If managed profile blocks
  # are not loaded yet, fall back to the scripts/replica-sync.ps1 wrapper.
  $actionTemplate = Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\ReplicaSync-task-action.ps1")
  $actionCommand = $actionTemplate -replace '__SCRIPT_PATH__', $scriptPath
  $action = New-ScheduledTaskAction -Execute $pwshPath -Argument "-NoLogo -ExecutionPolicy Bypass -Command `"$actionCommand`""
  $trigger = New-ScheduledTaskTrigger -Daily -At "12:00"
  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType InteractiveToken -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)

  Register-ScheduledTask `
    -TaskName $taskName `
    -Description "Run nucleus replica fallback sync daily at 12:00." `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

  Write-Output "replica-sync: ensured scheduled task '$taskName' (daily 12:00)"
}
