<#
.SYNOPSIS
  Synchronise Ollama models on Windows using the declarative manifest.


.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-AISync` from
  `src/hosts/Windows/modules/Invoke-AISync.ps1`.

  This mirrors `scripts/ai-sync.sh` on POSIX hosts so operators can run
  model convergence directly from `scripts/` on any platform.

.PARAMETER DryRun
  Print planned actions without executing pulls or removals (default: $false).

.PARAMETER PruneOnly
  Skip model pulls; only remove local models absent from the manifest (default: $false).

.PARAMETER ServerReadyTimeoutSeconds
  Bounded wait time for the Ollama server to become responsive before sync
  exits with a benign skip. Use 0 to disable waiting (default: 60).

.PARAMETER ServerReadyPollSeconds
  Poll interval while waiting for server readiness (default: 2).


.EXAMPLE
  .\scripts\ai-sync.ps1

.EXAMPLE
  .\scripts\ai-sync.ps1 -DryRun

.EXAMPLE
  .\scripts\ai-sync.ps1 -PruneOnly

.EXAMPLE
  .\scripts\ai-sync.ps1 -ServerReadyTimeoutSeconds 60
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$PruneOnly,
  [int]$ServerReadyTimeoutSeconds = 60,
  [int]$ServerReadyPollSeconds = 2
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\modules\Invoke-AISync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "ai-sync: module not found at '$modulePath'."
}

. $modulePath

Invoke-AISync -RepoRoot $repoRoot -DryRun:$DryRun -PruneOnly:$PruneOnly -ServerReadyTimeoutSeconds $ServerReadyTimeoutSeconds -ServerReadyPollSeconds $ServerReadyPollSeconds
