<#
.SYNOPSIS
  Reset local cloud replica sync state on Windows.

.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-ReplicaReset` from
  `src/hosts/windows/modules/system/Invoke-ReplicaReset.ps1`.

.PARAMETER DryRun
  Print planned reset actions without modifying local state.

.PARAMETER ReplicaId
  Optional replica id filter.
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [string]$ReplicaId
)

$ErrorActionPreference = 'Stop'

function Resolve-NucleusRepoRoot {
  $configPath = Join-Path -Path $HOME -ChildPath '.config\nucleus\repo-root'
  if (Test-Path -Path $configPath -PathType Leaf) {
    $configuredRoot = (Get-Content -Path $configPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($configuredRoot) -and (Test-Path -Path $configuredRoot -PathType Container)) {
      return $configuredRoot
    }
  }

  # git rev-parse stderr is suppressed because non-repo CWD is expected and
  # benign here; the result is validated before use.
  $gitRoot = (& git -C (Get-Location).Path rev-parse --show-toplevel 2>$null | Out-String).Trim()
  if (-not [string]::IsNullOrWhiteSpace($gitRoot) -and (Test-Path -Path $gitRoot -PathType Container)) {
    return $gitRoot
  }

  return (Join-Path -Path $HOME -ChildPath 'dev\nucleus')
}

$repoRoot = Resolve-NucleusRepoRoot
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\windows\modules\system\Invoke-ReplicaReset.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "replica-reset: module not found at '$modulePath'."
}

. $modulePath

Invoke-ReplicaReset -RepoRoot $repoRoot -DryRun:$DryRun -ReplicaId $ReplicaId
