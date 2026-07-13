<#
.SYNOPSIS
  Reset local cloud replica sync state on Windows.

.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-ReplicaReset` from
  `src/hosts/Windows/modules/system/Invoke-ReplicaReset.ps1`.

.PARAMETER DryRun
  Print planned reset actions without modifying local state (default: $false).

.PARAMETER ReplicaId
  Optional replica id filter (default: none; all replicas reset).

.EXAMPLE
  .\scripts\replica-reset.ps1

.EXAMPLE
  .\scripts\replica-reset.ps1 -DryRun

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

$fmtModulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $fmtModulePath -Force -DisableNameChecking

function Resolve-NucleusRepoRoot {
  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if (-not $repoRoot) {
    # undoc-supp: probe — path may not exist; $null check handles absence.
    $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
    if ($candidate -and (Test-Path "$candidate\src\flake.nix")) {
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
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\modules\system\Invoke-ReplicaReset.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "replica-reset: module not found at '$modulePath'."
}

. $modulePath

Invoke-ReplicaReset -RepoRoot $repoRoot -DryRun:$DryRun -ReplicaId $ReplicaId
