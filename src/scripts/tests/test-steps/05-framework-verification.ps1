Register-Step -Id "framework-verification" -Number 5 -Name "Framework verification" -Action {
  param($RepoRoot)
  $exitCode = 0
  $testDir = Join-Path -Path $RepoRoot -ChildPath 'tests' -AdditionalChildPath 'scripts'

  Write-Message "--- framework unit tests ---"
  & (Join-Path -Path $testDir -ChildPath 'step-runner-unit-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'test-lib-unit-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-step-file-structure-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  Write-Message "--- step-specific tests ---"
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '01-code-formatting-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '05-nix-lint-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '11-lockfile-validation-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '13-schema-validation-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '15-yaml-structural-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '16-package-manager-enforcement-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '17-suppression-audit-explicit-skip.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '17-suppression-audit-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '19-config-method-compliance-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '22-embedded-content-enforcement-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '21-22-scoped-mode-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '23-legacy-token-syntax-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '24-nix-test-eval-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  & (Join-Path -Path $testDir -ChildPath 'check-steps' -AdditionalChildPath '25-vm-manifest-regression-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  Write-Message "--- integration smoke tests ---"
  & (Join-Path -Path $testDir -ChildPath 'integration-smoke-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  Write-Message "--- documentation consistency tests ---"
  & (Join-Path -Path $testDir -ChildPath 'documentation-consistency-tests.ps1')
  if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

  return ($exitCode -eq 0)
}
