<#
.SYNOPSIS
  Ensure CamillaDSP heartbeat scheduled task is converged on Windows.

.DESCRIPTION
  Manages the CamillaDSP heartbeat lifecycle:
    1. Creates or removes a logon scheduled task that runs
       src/scripts/services/camilladsp-heartbeat.ps1 (persistent-loop daemon with
       exponential backoff).

  The heartbeat re-applies the config when CamillaDSP restarts after the
  underlying audio device disappears and reappears (same function as
  camilladsp-heartbeat on macOS/NixOS).

.PARAMETER Enabled
  True registers the heartbeat scheduled task.  False removes it.

.PARAMETER CamillaDSPPort
  CamillaDSP websocket API port (read from services.json by default).

.PARAMETER ConfigFile
  Path to the CamillaDSP config.yml (read from state by default).

.EXAMPLE
  Sync-CamillaDSPHeartbeatService -Enabled:$true

.EXAMPLE
  Sync-CamillaDSPHeartbeatService -Enabled:$false

.NOTES
  Environment variables:
    (none)

  Exit codes:
    0 on success; 1 on error.
#>
function Sync-CamillaDSPHeartbeatService {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory = $false)]
    [int]$CamillaDSPPort,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusCamillaDSPHeartbeat"

  if (-not $Enabled) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- task may not be registered yet; $null check below handles absence
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-NucleusInfo -CommandName 'camilladsp-heartbeat' "removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Read port from services.json if not provided.
  if (-not $PSBoundParameters.ContainsKey('CamillaDSPPort')) {
    $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
    # check-suppress:suppression_doc: probe -- services.json may not exist yet on first provision; fallback to default port
    $svc = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
    $CamillaDSPPort = if ($svc.camilladsp.network.websocket.port) { $svc.camilladsp.network.websocket.port } else { 1234 }
  }

  if (-not $PSBoundParameters.ContainsKey('ConfigFile')) {
    $ConfigFile = Join-Path -Path $HOME -ChildPath ".config\camilladsp\configs\config.yml"
  }

  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  # Resolve path to the shared heartbeat script.
  $heartbeatScript = Join-Path $PSScriptRoot "..\..\..\..\..\src\scripts\services\camilladsp-heartbeat.ps1"

  $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-WindowStyle Hidden -NoLogo -ExecutionPolicy Bypass -NoProfile -File `"$heartbeatScript`" -Port $CamillaDSPPort -ConfigFile `"$ConfigFile`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

  $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- task may not be registered yet; $null check below handles absence
  $wasRunning = $false
  if ($null -ne $existingTask) {
    # Capture running state before unregister: Unregister-ScheduledTask kills the
    # live instance, and the new registration won't auto-start until the next logon
    # trigger. Restarting explicitly closes the gap for a live session so the updated
    # heartbeat script is loaded by the running process (mirrors macOS bootout+bootstrap+kickstart).
    $wasRunning = $existingTask.State -eq 'Running'
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
  Write-NucleusInfo -CommandName 'camilladsp-heartbeat' "registered scheduled task '$taskName'"

  if ($wasRunning) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: task was just re-registered; stop is best-effort to ensure a clean restart with the updated script
    Start-ScheduledTask -TaskName $taskName
    Write-NucleusInfo -CommandName 'camilladsp-heartbeat' "restarted running scheduled task '$taskName' with updated script"
  }
}
