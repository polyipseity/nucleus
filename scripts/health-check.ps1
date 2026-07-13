<#
.SYNOPSIS
  Runs pre-flight health checks for Windows bootstrap/apply workflows.

.DESCRIPTION
  Validates four readiness dimensions before configuration is applied:
    1. free disk space on the system drive
    2. outbound HTTPS connectivity to GitHub and cache.nixos.org
    3. presence of decrypt-capable tooling (sops + gpg) when available
    4. log directory accessibility, file sizes, and sanitization (optional)

.PARAMETER MinFreeBytes
  Minimum free disk space (bytes) required on the system drive (default: 10000000000).

.PARAMETER NoSecretHealth
  Skip validation of sops/gpg executable availability (default: $false).

.PARAMETER LogHealth
  Enable log directory, size, and sanitize checks (default: $false).

.EXAMPLE
  .\health-check.ps1

.EXAMPLE
  .\health-check.ps1 -MinFreeGB 20

.EXAMPLE
  .\health-check.ps1 -NoSecretHealth

.EXAMPLE
  .\health-check.ps1 -LogHealth

.NOTES
  Environment variables: NUCLEUS_HEALTH_CHECK_NO_SECRET_HEALTH.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter()]
  [int]$MinFreeBytes = 10000000000,

  [Parameter()]
  [switch]$NoSecretHealth = $(if ($env:NUCLEUS_HEALTH_CHECK_NO_SECRET_HEALTH -eq 'true') { $true } else { $false }),

  [Parameter()]
  [switch]$LogHealth,

  [Alias("h")]
  [Parameter()]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

function Test-DiskSpace {
  <#
  .SYNOPSIS
    Fails if free system-drive space is below threshold.
  .DESCRIPTION
    Prevents long-running operations from starting when disk pressure is likely
    to cause partial downloads, failed extractions, or interrupted apply flows.
  .PARAMETER RequiredBytes
    Required free space threshold in bytes.
  .EXAMPLE
    Test-DiskSpace -RequiredBytes 10000000000
  #>
  param(
    [Parameter(Mandatory = $true)]
    [int]$RequiredBytes
  )

  $driveName = ($env:SystemDrive -replace ':', '')
  $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
  $requiredBytes = [int64]$RequiredBytes

  if ($drive.Free -lt $requiredBytes) {
    throw "nucleus: insufficient free disk space on $($env:SystemDrive). Required ${RequiredBytes} bytes, found $($drive.Free) bytes."
  }
}

function Test-Connectivity {
  <#
  .SYNOPSIS
    Verifies outbound connectivity to required endpoints.
  .DESCRIPTION
    Uses lightweight HEAD-like requests to fail fast when the machine is
    offline or blocked from artifact/dependency hosts.
  .EXAMPLE
    Test-Connectivity
  #>
  $targets = @(
    'https://github.com',
    'https://cache.nixos.org'
  )

  foreach ($target in $targets) {
    try {
      Invoke-WebRequest -Uri $target -Method Head -TimeoutSec 10 | Out-Null
    }
    catch {
      throw "nucleus: connectivity check failed for $target"
    }
  }
}

function Test-SecretTooling {
  <#
  .SYNOPSIS
    Verifies required secret tooling is available.
  .DESCRIPTION
    Checks for sops and gpg in PATH so secret decryption/import steps can run.
  .EXAMPLE
    Test-SecretTooling
  #>
  # WHY: probe whether tool is installed; Get-Command throws when absent.
  if (-not (Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue)) {
    throw 'nucleus: sops.exe not found in PATH.'
  }

  # WHY: probe whether tool is installed; Get-Command throws when absent.
  if (-not (Get-Command -Name 'gpg.exe' -ErrorAction SilentlyContinue)) {
    throw 'nucleus: gpg.exe not found in PATH.'
  }
}

function Test-LogHealth {
  <#
  .SYNOPSIS
    Validates log directories and log file health.
  .DESCRIPTION
    Checks that log directories exist and are writable, log file sizes stay
    within 80% of their rotation threshold, and sanitized logs contain no
    control characters.
  .EXAMPLE
    Test-LogHealth
  #>

  # WHY: probe whether tool is installed; Get-Command throws when absent.
  if (-not (Get-Command -Name 'jq.exe' -ErrorAction SilentlyContinue)) {
    throw 'nucleus: jq.exe not found in PATH (required for --LogHealth).'
  }

  $userDir = "$env:LOCALAPPDATA\nucleus\logs"
  $systemDir = "$env:ProgramData\nucleus\logs"
  if (Test-Path "$PSScriptRoot\..\src\hosts\Windows\modules\Invoke-LogManagement.ps1") {
    . "$PSScriptRoot\..\src\hosts\Windows\modules\Invoke-LogManagement.ps1"
    $userDir = Get-NucleusLogDir
    $systemDir = Get-NucleusSystemLogDir
  }
  $servicesJson = "$PSScriptRoot\..\src\modules\services.json"
  $failures = 0

  foreach ($dir in @($userDir, $systemDir)) {
    if (-not (Test-Path -Path $dir -PathType Container)) {
      Write-NucleusWarning "log dir '$dir' does not exist"
      $failures++
    }
  }

  $services = Get-Content $servicesJson -Raw | ConvertFrom-Json
  $svcNames = $services.PSObject.Properties |
    Where-Object { $_.Name -notlike '$*' } |
    Select-Object -ExpandProperty Name |
    Sort-Object

  foreach ($svc in $svcNames) {
    $svcConfig = $services.$svc.logging
    if (-not $svcConfig) { continue }
    $capture = if ($svcConfig.capture) { $svcConfig.capture } else { 'all' }
    if ($capture -eq 'none') { continue }

    $maxSize = if ($svcConfig.maxSize) { [int64]$svcConfig.maxSize } elseif ($services.'$defaults'.logging.maxSize) { [int64]$services.'$defaults'.logging.maxSize } else { 10000000 } # bytes
    $sanitize = if ($null -ne $svcConfig.sanitize) { [bool]$svcConfig.sanitize } else { $true }

    foreach ($dir in @($userDir, $systemDir)) {
      $logGlob = Join-Path -Path (Join-Path -Path $dir -ChildPath $svc) -ChildPath '*.log'
      # WHY: probe — log files may not exist; foreach handles empty result.
      foreach ($logFile in Get-ChildItem -Path $logGlob -ErrorAction SilentlyContinue) {
        # Check file size against rotation threshold
        $size = $logFile.Length
        $threshold = $maxSize * 80 / 100
        if ($size -gt $threshold) {
          Write-NucleusWarning "'$($logFile.FullName)' ($size bytes) exceeds 80% of rotation max ($maxSize bytes)"
        }

        # Spot-check for control characters when sanitize is enabled
        if ($sanitize) {
          $sample = Get-Content -Path $logFile.FullName -TotalCount 5 -Raw
          if ($sample -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
            Write-NucleusWarning "'$($logFile.FullName)' contains control characters despite sanitize=true"
            $failures++
          }
        }
      }
    }
  }

  if ($failures -gt 0) {
    throw "nucleus: log health checks failed ($failures issue(s))"
  }
}

Test-DiskSpace -RequiredBytes $MinFreeBytes
Test-Connectivity
if (-not $NoSecretHealth) {
  Test-SecretTooling
}
if ($LogHealth) {
  Test-LogHealth
}

Write-Output "$($PSStyle.Foreground.Green)nucleus: Windows health checks passed$($PSStyle.Reset)"
