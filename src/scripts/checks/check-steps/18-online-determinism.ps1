Register-Step -Number 18 -Name "Online determinism checks (--online)" -Action {
  param($HasArgs, $RepoRoot)
  $null = $HasArgs # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — positional binding requires HasArgs before RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  if ($script:ONLINE) {
    & "$r\scripts\bump-lockfile.ps1" -Verify
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
