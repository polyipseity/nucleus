Register-Step -Id "powershell-lint-test" -Number 2 -Name "PowerShell lint" -Action {
  param($RepoRoot)

  $exitCode = 0
  $pwshScript = Join-Path $RepoRoot 'scripts\check-pwsh.ps1'
  $settings = Join-Path $RepoRoot 'scripts\PSScriptAnalyzerSettings.test.psd1'

  & $pwshScript -Settings $settings
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  & $pwshScript -SkipStep PSSA -Paths (Join-Path $RepoRoot 'scripts\check-pwsh.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  $unknownSkipRejected = $false
  try {
    & $pwshScript -SkipStep UnknownName -Paths (Join-Path $RepoRoot 'scripts\check-pwsh.ps1')
    if ($LASTEXITCODE -ne 0) { $unknownSkipRejected = $true }
  } catch {
    $unknownSkipRejected = $true
  }
  if (-not $unknownSkipRejected) { $exitCode = 1 }

  return ($exitCode -eq 0)
}
