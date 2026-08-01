Register-Step -Id "powershell-lint-test" -Number 2 -Name "PowerShell lint" -Action {
  param($RepoRoot)

  $exitCode = 0
  $pwshScript = Join-Path $RepoRoot 'scripts\check-pwsh.ps1'
  $settings = Join-Path $RepoRoot 'scripts\PSScriptAnalyzerSettings.test.psd1'

  # PSScriptAnalyzer lint
  & $pwshScript -Settings $settings
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  # Syntax validation on known-good file
  & $pwshScript -SkipStep PSSA -Paths (Join-Path $RepoRoot 'scripts\check-pwsh.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  # Unknown -SkipStep name should fail
  $unknownSkipRejected = $false
  try {
    & $pwshScript -SkipStep UnknownName -Paths (Join-Path $RepoRoot 'scripts\check-pwsh.ps1')
    if ($LASTEXITCODE -ne 0) { $unknownSkipRejected = $true }
  } catch {
    # check-pwsh.ps1 signals unknown skip names with a terminating error.
    $unknownSkipRejected = $true
  }
  if (-not $unknownSkipRejected) { $exitCode = 1 }

  # Phase 0 step-runner regression tests
  Write-Message "--- step-runner regression tests (PS1) ---"
  & (Join-Path $RepoRoot 'tests\scripts\step-runner-regression-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  return ($exitCode -eq 0)
}
