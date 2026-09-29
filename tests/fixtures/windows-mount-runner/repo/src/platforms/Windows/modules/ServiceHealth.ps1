<#
.SYNOPSIS
  Test fixture: loads the real ServiceHealth module under a substituted repo root.
.DESCRIPTION
  rclone-mount.ps1 resolves both of its modules from $NUCLEUS_REPO_ROOT, so a fixture
  repo root can substitute one module while everything else stays real.  This file is
  the substitute for ServiceHealth.ps1 and contributes nothing of its own: it
  dot-sources the production module, so the health record the tests read is written by
  the same code that ships.

  The eight-level walk lands on the repository root from
  <repo>/tests/fixtures/windows-mount-runner/repo/src/platforms/Windows/modules.
#>

. (Resolve-Path (Join-Path $PSScriptRoot '../../../../../../../../src/platforms/Windows/modules/ServiceHealth.ps1')).Path
