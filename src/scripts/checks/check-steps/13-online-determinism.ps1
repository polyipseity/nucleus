Register-Step -Id "online-determinism" -Name "Online determinism checks (--online)" -Requires network -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # WHY: -Requires network already established --online, so this step always
  # performs the verification instead of probing $Context.Online itself.
  & "$r\scripts\update.ps1" -Verify
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "online determinism checks failed."
    return $false
  }
  Write-Message "online determinism checks passed."
  return $true
}
