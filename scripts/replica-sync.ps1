<#
.SYNOPSIS
  Synchronize cloud replicas on Windows using src/modules/users.json.

.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-ReplicaSync` from
  `src/hosts/Windows/modules/system/Invoke-ReplicaSync.ps1`.

.PARAMETER DryRun
  Print planned actions without executing rclone commands (default: $false).

.PARAMETER ReplicaId
  Optional replica id filter; when provided only the matching replica runs (default: none; all replicas run).

.EXAMPLE
  .\scripts\replica-sync.ps1

.EXAMPLE
  .\scripts\replica-sync.ps1 -DryRun

.NOTES
  Environment variables: NUCLEUS_DRY_RUN, NUCLEUS_REPLICA_ID.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [switch]$DryRun = $(if ($env:NUCLEUS_DRY_RUN -eq 'true') { $true } else { $false }),
  [string]$ReplicaId = $(if ($env:NUCLEUS_REPLICA_ID) { $env:NUCLEUS_REPLICA_ID } else { '' })
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

function Resolve-NucleusRepoRoot {
  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if (-not $repoRoot) {
    # WHY: probe — may be invoked outside repo checkouts; resolution handled below.
    $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
    if ($candidate) {
      return $candidate
    }
    throw "NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 or run from the repo checkout."
  }
  if (-not (Test-Path -Path $repoRoot -PathType Container)) {
    throw "NUCLEUS_REPO_ROOT path '$repoRoot' does not exist or is not a directory."
  }
  return $repoRoot
}

$repoRoot = Resolve-NucleusRepoRoot
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\modules\system\Invoke-ReplicaSync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "replica-sync: module not found at '$modulePath'."
}

. $modulePath

Invoke-ReplicaSync -RepoRoot $repoRoot -DryRun:$DryRun -ReplicaId $ReplicaId
