<#
.SYNOPSIS
  Synchronize cloud replicas on Windows using src/modules/users.json.

.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-ReplicaBisync` from
  `src/hosts/windows/modules/system/Invoke-ReplicaBisync.ps1`.

.PARAMETER DryRun
  Print planned actions without executing rclone commands.

.PARAMETER ReplicaId
  Optional replica id filter; when provided only the matching replica runs.
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [string]$ReplicaId
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\windows\modules\system\Invoke-ReplicaBisync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "replica-bisync: module not found at '$modulePath'."
}

. $modulePath

Invoke-ReplicaBisync -RepoRoot $repoRoot -DryRun:$DryRun -ReplicaId $ReplicaId
