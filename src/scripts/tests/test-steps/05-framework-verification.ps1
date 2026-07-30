Register-Step -Id "framework-verification" -Number 5 -Name "Framework verification" -Action {
  param($RepoRoot)
  $exitCode = 0
  $testDir = Join-Path -Path $RepoRoot -ChildPath 'tests' -AdditionalChildPaths 'scripts'

  Write-Message "--- framework unit tests ---"
  & (Join-Path -Path $testDir -ChildPath 'step-runner-unit-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'test-lib-unit-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-step-file-structure-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  Write-Message "--- step-specific tests ---"
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPaths '01-code-formatting-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPaths '05-nix-lint-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPaths '13-schema-validation-enforce-schema.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPaths '15-yaml-structural-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPaths '17-suppression-audit-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  Write-Message "--- integration smoke tests ---"
  & (Join-Path -Path $testDir -ChildPath 'integration-smoke-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  Write-Message "--- documentation consistency tests ---"
  & (Join-Path -Path $testDir -ChildPath 'documentation-consistency-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  return ($exitCode -eq 0)
}
