<#
.SYNOPSIS
  Synchronise locally installed Ollama models with the declarative manifest.


.DESCRIPTION
  Windows counterpart to scripts/ai.sh sync. Reads src/modules/configs/ollama/models.json,
  selects the `Windows` profile, then pulls every manifest model that is not
  installed and removes every installed model the manifest does not list.

  A no-op when the ollama binary is absent or the server is unreachable, so it is
  safe to call before the first apply.ps1 run.

.PARAMETER RepoRoot
  Root of the repository.

.PARAMETER DryRun
  Print planned actions without executing pulls or removals.

.PARAMETER GcOnly
  Skip model pulls and only remove unlisted models. Used by scripts/gc.ps1.

.PARAMETER ServerReadyTimeoutSeconds
  Bounded wait for the Ollama server before exiting with a benign skip. 0 disables
  waiting.

.NOTES
  Environment variables:
    OLLAMA_HOST  Ollama API endpoint (default: http://127.0.0.1:11434).
    NUCLEUS_HOST  Host identifier for model profile selection.
#>

function Invoke-AISync {
  <#
  .SYNOPSIS
    Converge locally installed Ollama models with the declarative manifest.

  .DESCRIPTION
    Reads src/modules/configs/ollama/models.json, selects the `Windows` profile, then pulls
    additions and removes unlisted models.  No-ops gracefully when ollama is
    absent or the server is unreachable.

  .PARAMETER RepoRoot
    Repository root path. Mandatory: caller must explicitly pass the repo root
    so they are aware of which repository's model manifest will be consulted
    and which machine context will be used for model operations.

  .PARAMETER DryRun
    Print planned actions without executing any ollama commands.

  .PARAMETER GcOnly
    Skip pulls; remove only locally installed models absent from the manifest.

  .PARAMETER ServerReadyTimeoutSeconds
    Bounded wait time for the Ollama server to become responsive before sync
    exits with a benign skip. Pass 0 to disable waiting.

  .OUTPUTS
    None.  Progress and skip messages are written to the host.

  .EXAMPLE
    Invoke-AISync -RepoRoot "C:\Users\admin\nucleus" -ServerReadyTimeoutSeconds 60
    Invoke-AISync -RepoRoot "C:\Users\admin\nucleus" -GcOnly -ServerReadyTimeoutSeconds 0
    Invoke-AISync -RepoRoot "C:\Users\admin\nucleus" -DryRun -ServerReadyTimeoutSeconds 60

  .NOTES
    Environment variables:
      OLLAMA_HOST  Ollama API endpoint (default: http://127.0.0.1:11434).
      NUCLEUS_HOST  Host identifier for model profile selection.

    Exit codes:
      0 on success; 1 on error.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [switch]$DryRun,
    [switch]$GcOnly,
    [Parameter(Mandatory)]
    [int]$ServerReadyTimeoutSeconds
  )

  $ErrorActionPreference = "Stop"

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $manifestPath     = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\configs\ollama\models.json"
  $lockfilePath     = Join-Path -Path $resolvedRepoRoot -ChildPath "src\lockfiles\lockfile.json"

  # WHY: point OLLAMA_HOST at Ollama rather than LiteLLM, so model list/pull/rm
  # talk to the inference backend instead of the gateway proxy. The default user
  # env var in user/env.dsc.yml points at LiteLLM (127.0.0.1:4000).
  # check-suppress:suppression_doc: probe -- services.json may not exist; $null-conditional access handles absence gracefully.
  $svc = Get-Content -Raw (Join-Path $resolvedRepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
  $env:OLLAMA_HOST = if ($svc.ollama.network.default) { "$($svc.ollama.network.default.host):$($svc.ollama.network.default.port)" } else { '127.0.0.1:11434' }

  # NUCLEUS_AI_SYNC_PROFILE overrides the resolved host key, which enables
  # cross-platform testing on Windows.
  if ([string]::IsNullOrWhiteSpace($env:NUCLEUS_REPO_ROOT)) {
    $env:NUCLEUS_REPO_ROOT = $resolvedRepoRoot
  }
  . (Join-Path -Path $resolvedRepoRoot -ChildPath 'src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1')
  $profileName = if ($env:NUCLEUS_AI_SYNC_PROFILE) { $env:NUCLEUS_AI_SYNC_PROFILE } else { Get-NucleusHostKey }

  # check-suppress:suppression_doc: probe -- ollama may not be installed; $null check handles absence.
  $ollamaCmd = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaCmd) {
    Write-NucleusInfo -CommandName 'ai' "ollama not found; skipping sync"
    return
  }

  if ($ServerReadyTimeoutSeconds -lt 0) {
    throw "ai: ServerReadyTimeoutSeconds must be zero or greater."
  }

  # WHY: wait rather than skip immediately. After a fresh apply the service can
  # still be starting even though the binary is installed.
  function Invoke-OllamaList {
    $output = @(& $ollamaCmd.Source list 2>&1)
    return @{
      ExitCode = $LASTEXITCODE
      Output   = $output
    }
  }

  $probeResult = Invoke-OllamaList
  $listExitCode = [int]$probeResult.ExitCode
  $listOutput = @($probeResult.Output)

  if ($listExitCode -ne 0 -and $ServerReadyTimeoutSeconds -gt 0) {
    Write-NucleusInfo -CommandName 'ai' "waiting up to ${ServerReadyTimeoutSeconds}s for ollama server readiness..."
    $deadline = (Get-Date).AddSeconds($ServerReadyTimeoutSeconds)
    do {
      Start-Sleep -Seconds 2
      $probeResult = Invoke-OllamaList
      $listExitCode = [int]$probeResult.ExitCode
      $listOutput = @($probeResult.Output)
      if ($listExitCode -eq 0) {
        break
      }
    } while ((Get-Date) -lt $deadline)
  }

  if ($listExitCode -ne 0) {
    Write-NucleusInfo -CommandName 'ai' "ollama server unavailable after waiting ${ServerReadyTimeoutSeconds}s; skipping sync"
    return
  }

  # Parse the manifest and extract the desired model list for the pc profile.
  $manifest      = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
  $desiredModels = @($manifest.models.$profileName)

  # NAME  ID  SIZE  MODIFIED, header plus rows; skip index 0 and take the first
  # whitespace-delimited field of each later non-blank line.
  $installedModels = @(
    $listOutput |
      Select-Object -Skip 1 |
      ForEach-Object { ($_ -split '\s+')[0] } |
      Where-Object { $_ -ne '' }
  )

  # Pull models present in the manifest but not locally installed.
  if (-not $GcOnly) {
    foreach ($model in $desiredModels) {
      if ($installedModels -contains $model) {
        continue
      }
      if ($DryRun) {
        Write-NucleusInfo -CommandName 'ai' "would pull $model"
      } else {
        Write-NucleusInfo -CommandName 'ai' "pulling $model"
        & $ollamaCmd.Source pull $model
        if ($LASTEXITCODE -ne 0) {
          Write-NucleusError -CommandName 'ai' "ollama pull $model failed with exit code $LASTEXITCODE"
        } else {
          # Verify the pull via ollama list
          $pullCheck = @(& $ollamaCmd.Source list 2>&1 | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -ne '' })
          if ($pullCheck -notcontains $model) {
            Write-NucleusError -CommandName 'ai' "$model was pulled but is not in 'ollama list'"
          } else {
            # optional lockfile digest check
            if (Test-Path $lockfilePath) {
              $lockfile = Get-Content -Raw -Path $lockfilePath | ConvertFrom-Json
              $modelParts = $model -split ':'
              $_modelName = $modelParts[0]
              $_modelTag  = if ($modelParts.Count -gt 1) { $modelParts[1] } else { 'latest' }
              $_lockEntry = @($lockfile.ollama.$profileName | Where-Object { $_.name -eq $_modelName -and $_.tag -eq $_modelTag })
              if ($_lockEntry -and $_lockEntry[0].digest) {
                $_expectedDigest = $_lockEntry[0].digest
                $_showJson = & $ollamaCmd.Source show --format json $model 2>&1 | Out-String
                $_actualDigest = ($_showJson | ConvertFrom-Json).digest
                if ($_actualDigest -and $_actualDigest -ne $_expectedDigest) {
                  Write-NucleusWarning -CommandName 'ai' "digest mismatch for $model (expected $_expectedDigest, got $_actualDigest)"
                } elseif ($_actualDigest) {
                  Write-NucleusInfo -CommandName 'ai' "digest verified for $model"
                }
              }
            }
          }
        }
      }
    }
  }

  # Remove locally installed models absent from the manifest.
  # WHY: the manifest is the canonical registry, so an unlisted model is orphaned
  # and removed to reclaim disk space.
  foreach ($model in $installedModels) {
    if ($desiredModels -contains $model) {
      continue
    }
    if ($DryRun) {
        Write-NucleusInfo -CommandName 'ai' "would remove $model"
    } else {
        Write-NucleusInfo -CommandName 'ai' "removing $model"
      & $ollamaCmd.Source rm $model
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'ai' "ollama rm $model failed with exit code $LASTEXITCODE"
      }
    }
  }

  $flags = @()
  if ($DryRun)    { $flags += "dry-run" }
  if ($GcOnly) { $flags += "gc-only" }
  $flagStr = if ($flags.Count -gt 0) { " ($($flags -join ', '))" } else { "" }
  Write-NucleusInfo -CommandName 'ai' "sync completed (profile=$profileName$flagStr)"
}
