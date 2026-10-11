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

# WHY a substituted boot id: Get-HealthBootId reaches for Get-CimInstance, which
#   does not exist on a POSIX test host, so production answers 'unknown' there
#   and Test-HealthBlocked fails closed for every record, including one whose
#   boot stamp is deliberately stale. The retry-loop case that pins the
#   previous-boot gate (a blocked record stops gating after a reboot) needs the
#   child process to see a stable, real-shaped boot id the way a Windows host
#   provides one. Same category as the Mount-Backend-Prepare stub beside it: a
#   lookup Windows owns that a POSIX host cannot answer.
function Get-HealthBootId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $IsWindows) { return 'fixture-boot-id' }
    try {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        if ($null -eq $boot) { return $script:HealthBootUnknown }
        return $boot.ToString('o')
    } catch {
        return $script:HealthBootUnknown
    }
}
