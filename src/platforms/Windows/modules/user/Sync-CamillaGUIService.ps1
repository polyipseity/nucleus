<#
.SYNOPSIS
  Ensure camillagui-backend startup task is converged on Windows.

.DESCRIPTION
  Manages the CamillaDSP web GUI lifecycle for each managed user:
    1. Creates or removes a logon scheduled task that starts
       camillagui_backend.exe with the config file.

  The config.yml is deployed to $HOME\.config\camillagui-backend\ by Invoke-CamillaGUISetup.

.PARAMETER Enabled
  True applies the config and registers the startup task.  False removes the
  startup task.

.EXAMPLE
  Sync-CamillaGUIService -Enabled:$true

.EXAMPLE
  Sync-CamillaGUIService -Enabled:$false

.NOTES
  Environment variables:
    (none)

  Exit codes:
    0 on success; 1 on error.
#>
function Sync-CamillaGUIService {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusCamillaGUI"

  if (-not $Enabled) {
    # DSC handles task removal via scheduler-user.dsc.yml. The PowerShell
    # module only removes the task when the feature is explicitly disabled
    # (cleanup path) — DSC does not provide a "disable and remove" toggle.
    # check-suppress:suppression_doc: probe -- task may not exist; $null check handles missing task.
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-NucleusInfo -CommandName 'camillagui-backend' "removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Task registration is handled by DSC (system/scheduler-user.dsc.yml).
  # This module verifies the binary exists and warns if not provisioned.
  $camillaguiBin = Join-Path $HOME ".local\bin\camillagui_backend\camillagui_backend.exe"
  if (-not (Test-Path $camillaguiBin)) {
    Write-NucleusInfo -CommandName 'camillagui-backend' "binary not found at $camillaguiBin; run Invoke-CamillaGUISetup first"
    return
  }

  Write-NucleusInfo -CommandName 'camillagui-backend' "task registration delegated to DSC (scheduler-user.dsc.yml)"
}
