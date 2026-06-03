<#
.SYNOPSIS
  Synchronise Ollama models on Windows using the declarative manifest.


.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-AISync` from
  `src/hosts/Windows/modules/Invoke-AISync.ps1`.

  This mirrors `scripts/ai-sync.sh` on POSIX hosts so operators can run
  model convergence directly from `scripts/` on any platform.

.PARAMETER DryRun
  Print planned actions without executing pulls or removals.

.PARAMETER PruneOnly
  Skip model pulls; only remove local models absent from the manifest.

.PARAMETER ServerReadyTimeoutSeconds
  Bounded wait time for the Ollama server to become responsive before sync
  exits with a benign skip. Use 0 to disable waiting.
  Falls back to $env:OLLAMA_READY_TIMEOUT_SECONDS when unset.

.PARAMETER ServerReadyPollSeconds
  Poll interval while waiting for server readiness. Defaults to 2 when unset.
  Falls back to $env:OLLAMA_READY_POLL_SECONDS when unset.


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

# Environment variable fallback (cross-platform parity with ai-sync.sh).
if (-not $PSBoundParameters.ContainsKey('ServerReadyTimeoutSeconds') -and $env:OLLAMA_READY_TIMEOUT_SECONDS) {
  $ServerReadyTimeoutSeconds = [int]$env:OLLAMA_READY_TIMEOUT_SECONDS
}
if (-not $PSBoundParameters.ContainsKey('ServerReadyPollSeconds') -and $env:OLLAMA_READY_POLL_SECONDS) {
  $ServerReadyPollSeconds = [int]$env:OLLAMA_READY_POLL_SECONDS
}

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\modules\Invoke-AISync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "ai-sync: module not found at '$modulePath'."
}

. $modulePath

Invoke-AISync -RepoRoot $repoRoot -DryRun:$DryRun -PruneOnly:$PruneOnly -ServerReadyTimeoutSeconds $ServerReadyTimeoutSeconds -ServerReadyPollSeconds $ServerReadyPollSeconds
