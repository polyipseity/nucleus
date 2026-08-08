Register-Step -Id "powershell-lint-test" -Number 2 -Name "PowerShell lint smoke" -Action {
  param($RepoRoot)

  $testScript = Join-Path -Path $RepoRoot -ChildPath 'tests' -AdditionalChildPath 'scripts' -AdditionalChildPath 'check-pwsh-tests.ps1'
  & $testScript
  return ($LASTEXITCODE -eq 0)
}
