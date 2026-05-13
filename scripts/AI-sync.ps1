<#
.SYNOPSIS
  Synchronise Ollama models on Windows using the declarative manifest.


.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-AISync` from
  `src/hosts/windows/modules/Invoke-AISync.ps1`.

  This mirrors `scripts/AI-sync.sh` on POSIX hosts so operators can run
  model convergence directly from `scripts/` on any platform.

.PARAMETER DryRun
  Print planned actions without executing pulls or removals.

.PARAMETER PruneOnly
  Skip model pulls; only remove local models absent from the manifest.

.PARAMETER ServerReadyTimeoutSeconds
  Bounded wait time for the Ollama server to become responsive before sync
  exits with a benign skip. Use 0 to disable waiting.


.EXAMPLE
  .\scripts\AI-sync.ps1

.EXAMPLE
  .\scripts\AI-sync.ps1 -DryRun

.EXAMPLE
  .\scripts\AI-sync.ps1 -PruneOnly

.EXAMPLE
  .\scripts\AI-sync.ps1 -ServerReadyTimeoutSeconds 60
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$PruneOnly,
  [int]$ServerReadyTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\windows\modules\Invoke-AISync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "AI-sync: module not found at '$modulePath'."
}

. $modulePath

Invoke-AISync -RepoRoot $repoRoot -DryRun:$DryRun -PruneOnly:$PruneOnly -ServerReadyTimeoutSeconds $ServerReadyTimeoutSeconds
