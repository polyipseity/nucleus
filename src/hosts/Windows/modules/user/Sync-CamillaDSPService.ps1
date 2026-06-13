<#
.SYNOPSIS
  Ensure CamillaDSP startup task is converged on Windows.

.DESCRIPTION
  Manages the CamillaDSP audio processor lifecycle for each managed user:
    1. Creates or removes a logon scheduled task that starts camilladsp.exe
       with the websocket API enabled.

  The config.yml is deployed to $HOME\.config\camilladsp\ by Invoke-CamillaDSPSetup.

.PARAMETER Enabled
  True applies the config and registers the startup task.  False removes the
  startup task.

.EXAMPLE
  Sync-CamillaDSPService -Enabled:$true

.EXAMPLE
  Sync-CamillaDSPService -Enabled:$false

.NOTES
  Environment variables:
    (none)

  Exit codes:
    0 on success; 1 on error.
#>
function Sync-CamillaDSPService {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusCamillaDSP"
  $logDir = Get-NucleusLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "camilladsp"
  $null = New-Item -Path $serviceLogDir -ItemType Directory -Force
  $logFile = Join-Path -Path $serviceLogDir -ChildPath "combined.log"

  if (-not $Enabled) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "camilladsp: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Config is deployed to $HOME\.config\camilladsp\ by Invoke-CamillaDSPSetup.
  $null = New-Item -Path $logDir -ItemType Directory -Force

  # Find the camilladsp binary.
  $camilladspCmd = Get-Command -Name "camilladsp.exe" -ErrorAction SilentlyContinue
  if ($null -eq $camilladspCmd) {
    Write-Output "camilladsp: binary not found in PATH; run Invoke-CamillaDSPSetup first"
    return
  }
  $camilladspBin = $camilladspCmd.Source

  # Read port from services.json (single source of truth).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $svc = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
  $wsPort = if ($svc.camilladsp.network.websocket.port) { $svc.camilladsp.network.websocket.port } else { 1234 }

  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  $configPath = Join-Path -Path $HOME -ChildPath ".config\camilladsp\config.yml"
  $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-WindowStyle Hidden -NoLogo -ExecutionPolicy Bypass -NoProfile -Command `"& '$camilladspBin' -o '$logFile' -p $wsPort -w '$configPath'`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

  $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
  Write-Output "camilladsp: registered scheduled task '$taskName'"
}
