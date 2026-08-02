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
  $logFile = Join-Path -Path $serviceLogDir -ChildPath "combined.log"

  if (-not $Enabled) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- task may not be registered yet; $null check below handles absence
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "camilladsp: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Compute deterministic install path (must match Invoke-CamillaDSPSetup).
  $camilladspBin = Join-Path $HOME ".local\bin\camilladsp.exe"
  if (-not (Test-Path $camilladspBin)) {
    Write-Output "camilladsp: binary not found at $camilladspBin; run Invoke-CamillaDSPSetup first"
    return
  }

  # Read port from services.json (single source of truth).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  # check-suppress:suppression_doc: probe -- services.json may not exist yet on first provision; fallback to default port
  $svc = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
  $wsPort = if ($svc.camilladsp.network.websocket.port) { $svc.camilladsp.network.websocket.port } else { 1234 }

  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  # Compute config path for wrapper script.
  $configPath = Join-Path -Path $HOME -ChildPath ".config\camilladsp\configs\config.yml"

  # Write the wrapper script that auto-applies config via WS API.
  $wrapperDir = Join-Path -Path $HOME -ChildPath ".config\camilladsp\bin"
  $null = New-Item -Path $wrapperDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  $wrapperScriptPath = Join-Path -Path $wrapperDir -ChildPath "autoconfig.ps1"
  $wrapperScriptPathSource = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\CamillaDSP-autoconfig.ps1"
  $wrapperContent = Get-Content -Raw $wrapperScriptPathSource
  Set-Content -Path $wrapperScriptPath -Value $wrapperContent -NoNewline

  $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-WindowStyle Hidden -NoLogo -ExecutionPolicy Bypass -NoProfile -File `"$wrapperScriptPath`" -CamillaDSPBin `"$camilladspBin`" -Port $wsPort -ConfigFile `"$configPath`" -LogFile `"$logFile`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

  $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- task may not be registered yet; $null check below handles absence
  if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
  Write-Output "camilladsp: registered scheduled task '$taskName'"
}
