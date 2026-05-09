<#
.SYNOPSIS
  Synchronise Ollama models on Windows using the declarative manifest.

.DESCRIPTION
  Thin scripts/ entrypoint wrapper around `Invoke-AiSync` from
  `src/hosts/windows/modules/invoke-aisync.ps1`.

  This mirrors `scripts/ai-sync.sh` on POSIX hosts so operators can run
  model convergence directly from `scripts/` on any platform.

.PARAMETER DryRun
  Print planned actions without executing pulls or removals.

.PARAMETER PruneOnly
  Skip model pulls; only remove local models absent from the manifest.

.EXAMPLE
  .\scripts\ai-sync.ps1

.EXAMPLE
  .\scripts\ai-sync.ps1 -DryRun

.EXAMPLE
  .\scripts\ai-sync.ps1 -PruneOnly
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$PruneOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\hosts\windows\modules\invoke-aisync.ps1'

if (-not (Test-Path -LiteralPath $modulePath)) {
  throw "ai-sync: module not found at '$modulePath'."
}

. $modulePath

Invoke-AiSync -RepoRoot $repoRoot -DryRun:$DryRun -PruneOnly:$PruneOnly
