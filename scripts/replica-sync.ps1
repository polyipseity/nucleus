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
#>
[CmdletBinding()]
param(
  [switch]$DryRun = $(if ($env:NUCLEUS_DRY_RUN -eq 'true') { $true } else { $false }),
  [string]$ReplicaId = $(if ($env:NUCLEUS_REPLICA_ID) { $env:NUCLEUS_REPLICA_ID } else { '' })
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
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\modules\system\Invoke-ReplicaSync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "replica-sync: module not found at '$modulePath'."
}

. $modulePath

Invoke-ReplicaSync -RepoRoot $repoRoot -DryRun:$DryRun -ReplicaId $ReplicaId
