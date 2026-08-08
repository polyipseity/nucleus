Register-Step -Id "framework-verification" -Number 5 -Name "Framework verification" -Action {
  param($RepoRoot)
  $exitCode = 0
  $testDir = Join-Path -Path $RepoRoot -ChildPath 'tests' -AdditionalChildPath 'scripts'

  Write-Message "--- framework unit tests ---"
  & (Join-Path -Path $testDir -ChildPath 'step-runner-unit-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'test-lib-unit-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'deny-list-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'android-config-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  Write-Message "--- step-specific tests ---"
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '09-schema-validation-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'load-user-registry-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  return ($exitCode -eq 0)
}
