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
  $logDir = Get-NucleusLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "camillagui-backend"
  $logFile = Join-Path -Path $serviceLogDir -ChildPath "combined.log"

  if (-not $Enabled) {
    # undoc-supp: probe — task may not exist; $null check handles missing task.
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "camillagui-backend: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Compute deterministic install path (must match Invoke-CamillaGUISetup).
  $camillaguiBin = Join-Path $HOME ".local\bin\camillagui_backend\camillagui_backend.exe"
  if (-not (Test-Path $camillaguiBin)) {
    Write-Output "camillagui-backend: binary not found at $camillaguiBin; run Invoke-CamillaGUISetup first"
    return
  }

  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  $configPath = Join-Path -Path $HOME -ChildPath ".config\camillagui-backend\config.yml"
  $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-WindowStyle Hidden -NoLogo -ExecutionPolicy Bypass -NoProfile -Command `"& '$camillaguiBin' -c '$configPath' *>> '$logFile'`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

  # undoc-supp: probe — task may not exist; $null check handles missing task.
  $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
  Write-Output "camillagui-backend: registered scheduled task '$taskName'"
}
