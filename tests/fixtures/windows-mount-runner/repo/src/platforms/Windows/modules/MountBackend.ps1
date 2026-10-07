<#
.SYNOPSIS
  Test fixture: the Windows mount backend with WinFsp preparation stubbed out.
.DESCRIPTION
  The companion ServiceHealth.ps1 in this directory explains why a substituted repo
  root exists at all.  This file dot-sources the real MountBackend.ps1 and then
  replaces exactly one function:

    Mount-Backend-Prepare  reads the WinFsp registry key and the WinFsp.Launcher
                            service, neither of which exists off Windows, so on a POSIX
                            test host it answers 20 and the runner exits at
                            "backend requires user action" before the attach loop, the
                            exhaustion record and the capture-file handling are ever
                            reached.  The stub reports the provider as ready, or, under
                            NUCLEUS_TEST_PREPARE_BLOCKED=1, the provider refusal the
                            production registry-probe branch answers when WinFsp is
                            missing: a blocked record and rc 20.

  Everything else, including the probe and the failure classifier, is the production
  implementation, so the tests exercise the real answers rather than stand-ins.

  The eight-level walk lands on the repository root from
  <repo>/tests/fixtures/windows-mount-runner/repo/src/platforms/Windows/modules.
#>

. (Resolve-Path (Join-Path $PSScriptRoot '../../../../../../../../src/platforms/Windows/modules/MountBackend.ps1')).Path

function Mount-Backend-Prepare {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)

    # NUCLEUS_TEST_PREPARE_BLOCKED=1 makes the stub answer as the production
    # registry-probe branch does when WinFsp is missing: a provider-refusal
    # record and rc 20, which the runner turns into the prepare-block notice and
    # exit 0 before the attach loop.
    if ($env:NUCLEUS_TEST_PREPARE_BLOCKED -eq '1') {
        Set-HealthBlocked -Instance $Instance -Class 'provider-refusal' -Remedy 'install WinFsp via winget install WinFsp.WinFsp'
        return 20
    }
    return 0
}
