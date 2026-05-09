<#
.SYNOPSIS
  Synchronise locally installed Ollama models with the declarative manifest.

.DESCRIPTION
  Windows counterpart to scripts/ai-sync.sh.  Reads the model manifest at
  src/modules/ai/models.json, selects the `pc` profile (always used on
  Windows), and converges the locally installed Ollama model set:

    1. Pull any model in the manifest that is not already installed.
       (Skipped when -PruneOnly is specified.)
    2. Remove any locally installed model absent from the manifest.
       The manifest is the single source of truth; orphaned models are
       removed to reclaim disk space.

  The function is a no-op when the ollama binary is absent or the Ollama
  server is unreachable, so it is safe to call at any time — including
  before the first apply.ps1 run.

.PARAMETER RepoRoot
  Root of the repository.  Defaults to two levels above $PSScriptRoot
  (i.e. the repo root when called from src\modules\windows).

.PARAMETER DryRun
  Print planned actions without executing pulls or removals.

.PARAMETER PruneOnly
  Skip model pulls; only remove locally installed models absent from the
  manifest.  Used by scripts/gc.ps1 for space reclamation without
  downloading new models.

.EXAMPLE
  . .\src\modules\windows\ai-sync.ps1
  Invoke-AiSync
  Invoke-AiSync -PruneOnly
  Invoke-AiSync -DryRun
#>

function Invoke-AiSync {
  <#
  .SYNOPSIS
    Converge locally installed Ollama models with the declarative manifest.

  .DESCRIPTION
    Reads src/modules/ai/models.json, selects the `pc` profile, then pulls
    additions and removes unlisted models.  No-ops gracefully when ollama is
    absent or the server is unreachable.

  .PARAMETER RepoRoot
    Repository root path.  Auto-detected from $PSScriptRoot when omitted.

  .PARAMETER DryRun
    Print planned actions without executing any ollama commands.

  .PARAMETER PruneOnly
    Skip pulls; remove only locally installed models absent from the manifest.

  .OUTPUTS
    None.  Progress and skip messages are written to the host.

  .EXAMPLE
    Invoke-AiSync
    Invoke-AiSync -PruneOnly
    Invoke-AiSync -DryRun
  #>
  [CmdletBinding()]
  param(
    [string]$RepoRoot  = (Join-Path -Path $PSScriptRoot -ChildPath "..\.."),
    [switch]$DryRun,
    [switch]$PruneOnly
  )

  $ErrorActionPreference = "Stop"

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $manifestPath     = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\ai\models.json"

  # Windows always uses the `pc` profile — the manifest's `mac` profile is
  # tuned for Apple Silicon unified-memory hardware and is not applicable.
  $profile = "pc"

  # Skip gracefully when ollama is not installed or not on PATH.
  # Existence probe — absent binary is expected and benign before Ollama
  # has been installed by WinGet (system.dsc.yml).
  $ollamaCmd = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaCmd) {
    Write-Output "ai-sync: ollama not found; skipping sync"
    return
  }

  # Probe the server with `ollama list`.  A non-zero exit means the server
  # is not yet running; this is expected and benign immediately after WinGet
  # installs the service before the first user login or service start.
  # The failure is intentionally expected in this context; the exit code is
  # checked (LASTEXITCODE) so unexpected failures still surface.
  $listOutput = & $ollamaCmd.Source list 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ai-sync: ollama server unavailable; skipping sync"
    return
  }

  # Parse the manifest and extract the desired model list for the pc profile.
  $manifest      = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
  $desiredModels = @($manifest.models.$profile)

  # Parse `ollama list` output.  Format: NAME  ID  SIZE  MODIFIED (header + rows).
  # Skip the header line (index 0) and extract the first whitespace-delimited
  # field (model name) from each subsequent non-blank line.
  $installedModels = @(
    $listOutput |
      Select-Object -Skip 1 |
      ForEach-Object { ($_ -split '\s+')[0] } |
      Where-Object { $_ -ne '' }
  )

  # Pull models present in the manifest but not locally installed.
  if (-not $PruneOnly) {
    foreach ($model in $desiredModels) {
      if ($installedModels -contains $model) {
        continue
      }
      if ($DryRun) {
        Write-Output "ai-sync: would pull $model"
      } else {
        Write-Output "ai-sync: pulling $model"
        & $ollamaCmd.Source pull $model
        if ($LASTEXITCODE -ne 0) {
          Write-Error "ai-sync: ollama pull $model failed with exit code $LASTEXITCODE"
        }
      }
    }
  }

  # Remove locally installed models absent from the manifest.
  # The manifest is the single source of truth; any model not listed here
  # is considered orphaned and is removed to reclaim disk space.
  foreach ($model in $installedModels) {
    if ($desiredModels -contains $model) {
      continue
    }
    if ($DryRun) {
        Write-Output "ai-sync: would remove $model"
    } else {
        Write-Output "ai-sync: removing $model"
      & $ollamaCmd.Source rm $model
      if ($LASTEXITCODE -ne 0) {
        Write-Error "ai-sync: ollama rm $model failed with exit code $LASTEXITCODE"
      }
    }
  }

  $flags = @()
  if ($DryRun)    { $flags += "dry-run" }
  if ($PruneOnly) { $flags += "prune-only" }
  $flagStr = if ($flags.Count -gt 0) { " ($($flags -join ', '))" } else { "" }
  Write-Output "ai-sync: sync completed (profile=$profile$flagStr)"
}
