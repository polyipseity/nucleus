Register-Step -Id "powershell-lint-test" -Number 2 -Name "PowerShell lint (PSSA)" -Action {
  param($RepoRoot)

  $pwshScript = Join-Path -Path $RepoRoot -ChildPath 'scripts\check-pwsh.ps1'
  $settings = Join-Path -Path $RepoRoot -ChildPath 'scripts\PSScriptAnalyzerSettings.test.psd1'

  & $pwshScript -SkipStep Syntax -Settings $settings
  return ($LASTEXITCODE -eq 0)
}
