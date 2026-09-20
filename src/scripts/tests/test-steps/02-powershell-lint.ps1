Register-Step -Id "powershell-lint-test" -Name "PowerShell lint (PSSA)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $pwshScript = Join-Path -Path $RepoRoot -ChildPath 'src\scripts\checks\check-pwsh.ps1'
  $settings = Join-Path -Path $RepoRoot -ChildPath 'scripts\test-PSScriptAnalyzerSettings.psd1'

  & $pwshScript -OnlyStep PSSA -Settings $settings
  return ($LASTEXITCODE -eq 0)
}
