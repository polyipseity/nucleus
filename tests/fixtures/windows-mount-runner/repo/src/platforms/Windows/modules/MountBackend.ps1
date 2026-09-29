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
                            reached.  The stub reports the provider as ready.

  Everything else, including the probe and the failure classifier, is the production
  implementation, so the tests exercise the real answers rather than stand-ins.

  The eight-level walk lands on the repository root from
  <repo>/tests/fixtures/windows-mount-runner/repo/src/platforms/Windows/modules.
#>

. (Resolve-Path (Join-Path $PSScriptRoot '../../../../../../../../src/platforms/Windows/modules/MountBackend.ps1')).Path

function Mount-Backend-Prepare {
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- the real function keys a health record on the instance; the stub reports the provider ready and has no record to key
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)
    return 0
}
