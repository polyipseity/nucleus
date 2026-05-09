<#
.SYNOPSIS
  Runs pre-flight health checks for Windows bootstrap/apply workflows.

.DESCRIPTION
  Validates three readiness dimensions before configuration is applied:
    1. free disk space on the system drive
    2. outbound HTTPS connectivity to GitHub and cache.nixos.org
    3. presence of decrypt-capable tooling (sops + gpg) when available

.PARAMETER MinFreeGB
  Minimum free disk space (GiB) required on the system drive.

.PARAMETER SkipSecretTooling
  Skip validation of sops/gpg executable availability.

.EXAMPLE
  .\health-check.ps1

.EXAMPLE
  .\health-check.ps1 -MinFreeGB 20
#>
[CmdletBinding()]
param(
  [Parameter()]
  [int]$MinFreeGB = 10,

  [Parameter()]
  [switch]$SkipSecretTooling
)

$ErrorActionPreference = 'Stop'

function Test-DiskSpace {
  <#
  .SYNOPSIS
    Fails if free system-drive space is below threshold.
  .DESCRIPTION
    Prevents long-running operations from starting when disk pressure is likely
    to cause partial downloads, failed extractions, or interrupted apply flows.
  .PARAMETER RequiredGiB
    Required free space threshold in GiB.
  .EXAMPLE
    Test-DiskSpace -RequiredGiB 10
  #>
  param(
    [Parameter(Mandatory = $true)]
    [int]$RequiredGiB
  )

  $driveName = ($env:SystemDrive -replace ':', '')
  $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
  $requiredBytes = [int64]$RequiredGiB * 1GB

  if ($drive.Free -lt $requiredBytes) {
    throw "nucleus: insufficient free disk space on $($env:SystemDrive). Required ${RequiredGiB} GiB, found $([math]::Floor($drive.Free / 1GB)) GiB."
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
  if (-not (Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue)) {
    throw 'nucleus: sops.exe not found in PATH.'
  }

  if (-not (Get-Command -Name 'gpg.exe' -ErrorAction SilentlyContinue)) {
    throw 'nucleus: gpg.exe not found in PATH.'
  }
}

Test-DiskSpace -RequiredGiB $MinFreeGB
Test-Connectivity
if (-not $SkipSecretTooling) {
  Test-SecretTooling
}

Write-Output "$($PSStyle.Foreground.Green)nucleus: Windows health checks passed$($PSStyle.Reset)"
