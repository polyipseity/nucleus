Register-Step -Id "online-determinism" -Name "Online determinism checks (--online)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  if ($Context.Online) {
    & "$r\scripts\update.ps1" -Verify
    if ($LASTEXITCODE -ne 0) {
      Write-ErrorMessage "online determinism checks failed."
      return $false
    }
    Write-Message "online determinism checks passed."
  } else {
    Write-Message "skipping (use --online to run online determinism checks)."
  }
  return $true
}
