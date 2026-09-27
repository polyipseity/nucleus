Register-Step -Id "powershell-lint" -Name "PowerShell syntax" -Platform windows -Mode any -Requires none -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $ps1Files = $Context.Ps1Files
  if (-not $ps1Files) { $ps1Files = @() }

  # A scoped run with no .ps1 in scope checks nothing. Without this the analyzer
  # falls back to `git ls-files` and lints every PowerShell file in the repo,
  # which is the inverse of the scoped contract.
  if ($Context.HasArgs -and $ps1Files.Count -eq 0) {
    Write-Message '0 PowerShell files in scope — syntax check not run.'
    return $true
  }

  & "$r\scripts\check.ps1" pwsh @ps1Files
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "PowerShell check failed."
    return $false
  }

  Write-Message "PowerShell syntax check passed."
  return $true
}
