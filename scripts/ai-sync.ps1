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

.PARAMETER GcOnly
  Skip model pulls; only remove local models absent from the manifest (default: $false).


.EXAMPLE
  .\scripts\ai-sync.ps1

.EXAMPLE
  .\scripts\ai-sync.ps1 -DryRun

.EXAMPLE
  .\scripts\ai-sync.ps1 -GcOnly

.NOTES
  Environment variables: NUCLEUS_DRY_RUN, NUCLEUS_AI_SYNC_GC_ONLY, NUCLEUS_REPO_ROOT, NUCLEUS_AI_SYNC_TIMEOUT, NUCLEUS_AI_SYNC_POLL.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [switch]$DryRun = $(if ($env:NUCLEUS_DRY_RUN -eq 'true') { $true } else { $false }),
  [switch]$GcOnly = { $env:NUCLEUS_AI_SYNC_GC_ONLY -eq 'true' }.Invoke()
)

$ErrorActionPreference = 'Stop'

$repoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path }
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\modules\Invoke-AISync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "ai-sync: module not found at '$modulePath'."
}

. $modulePath

Invoke-AISync -RepoRoot $repoRoot -DryRun:$DryRun -GcOnly:$GcOnly -ServerReadyTimeoutSeconds $(if ($env:NUCLEUS_AI_SYNC_TIMEOUT) { [int]$env:NUCLEUS_AI_SYNC_TIMEOUT } else { 60 }) -ServerReadyPollSeconds $(if ($env:NUCLEUS_AI_SYNC_POLL) { [int]$env:NUCLEUS_AI_SYNC_POLL } else { 2 })
