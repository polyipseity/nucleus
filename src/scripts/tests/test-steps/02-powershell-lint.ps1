Register-Step -Id "powershell-lint-test" -Name "PowerShell lint (PSSA)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $pwshScript = Join-Path -Path $RepoRoot -ChildPath 'scripts\check-pwsh.ps1'
  $settings = Join-Path -Path $RepoRoot -ChildPath 'scripts\test-PSScriptAnalyzerSettings.psd1'

  & $pwshScript -SkipStep Syntax -Settings $settings
  return ($LASTEXITCODE -eq 0)
}
