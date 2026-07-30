Register-Step -Number 2 -Name "PowerShell lint" -Action {
  param($HasArgs, $RepoRoot)
  $null = $HasArgs # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — positional binding requires HasArgs before RepoRoot
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
  & $pwshScript -SkipStep UnknownName -Paths (Join-Path $RepoRoot 'scripts\check-pwsh.ps1')
  if ($LASTEXITCODE -eq 0) { $exitCode = 1 }

  return ($exitCode -eq 0)
}
