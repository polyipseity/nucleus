<#
.SYNOPSIS
  Pester tests for the Windows health record's liveness stamp.

.DESCRIPTION
  src/scripts/lib/service-health.sh keeps two sibling stamps: lastSuccess on a
  successful unit action and lastLive on a successful liveness probe.  A
  lastSuccess that advances while lastLive does not is the visible signature of a
  job that was alive and not working, so the pair has to exist on Windows too.
  On Windows Set-HealthSuccess writes both from one clock read, so the pair
  cannot diverge here and that signature is POSIX-only.

  The module's other contracts stay in the neighbouring service-health.Tests.ps1
  suite; this file covers the liveness stamp, the writes that must leave it
  alone, and its tolerance for records written before the field existed.

  Get-CimInstance is stubbed because boot-id lookup is the only WMI dependency,
  so the suite runs on macOS and Linux as well as Windows.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/ServiceHealth.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $modulesDir = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules'
  . (Join-Path $modulesDir 'ServiceHealth.ps1')

  if (-not (Get-Command -Name 'Get-CimInstance' -ErrorAction Ignore)) {
    Set-Item -Path 'Function:Get-CimInstance' -Value {
      param([string]$ClassName)
      if ($ClassName -ne 'Win32_OperatingSystem') { throw "stub: unexpected class $ClassName" }
      [PSCustomObject]@{ LastBootUpTime = [datetime]'2026-09-19T16:17:08' }
    }
  }

  # A per-run root keeps records out of the real user profile.
  $script:OriginalLocalAppData = $env:LOCALAPPDATA
  $script:HealthRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("service-health-live-{0}" -f [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $script:HealthRoot -Force > $null
  $env:LOCALAPPDATA = $script:HealthRoot

  # The record shape written before lastLive existed.  Initialize-HealthRecord
  # never rewrites an existing file, so an upgrade keeps records of this shape.
  $script:LegacyRecordJson = '{"state":"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":"unknown","lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}'
}

AfterAll {
  if ($null -eq $script:OriginalLocalAppData) {
    Remove-Item Env:LOCALAPPDATA -ErrorAction Ignore
  }
  else {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
  }
  Remove-Item -Path $script:HealthRoot -Recurse -Force -ErrorAction Ignore
}

Describe 'Initialize-HealthRecord lastLive' {
  It 'starts at zero so the field exists before any probe' {
    Initialize-HealthRecord -Instance 'live-init'

    (Get-HealthField -Instance 'live-init' -Field 'lastLive') | Should -Be 0
  }
}

Describe 'Set-HealthSuccess liveness stamp' {
  It 'advances lastLive on a live probe' {
    Initialize-HealthRecord -Instance 'live-advance'
    # Seeded away from the clock so the assertion tells a fresh stamp from the
    # value the record already carried.
    Set-HealthField -Instance 'live-advance' -Field 'lastLive' -Value 5

    Set-HealthSuccess -Instance 'live-advance'

    (Get-HealthField -Instance 'live-advance' -Field 'lastLive') | Should -BeGreaterThan 5
  }

  It 'stamps lastLive and lastSuccess from the same observation' {
    Initialize-HealthRecord -Instance 'live-pair'

    Set-HealthSuccess -Instance 'live-pair'

    $record = Get-Content -Raw (Get-HealthStateFile -Instance 'live-pair') | ConvertFrom-Json
    $record.lastSuccess | Should -BeGreaterThan 0
    $record.lastLive | Should -Be $record.lastSuccess -Because 'one probe reads the clock once, so the pair stays comparable'
  }

  It 'leaves the crash-loop reading of lastSuccess unchanged' {
    Initialize-HealthRecord -Instance 'live-consec'
    Add-HealthRestart -Instance 'live-consec'

    Set-HealthSuccess -Instance 'live-consec'

    (Get-HealthField -Instance 'live-consec' -Field 'lastSuccess') | Should -BeGreaterThan 0
    (Get-HealthConsecutiveFailureCount -Instance 'live-consec') | Should -Be 0
  }
}

Describe 'lastLive moves only on a live probe' {
  It 'does not advance when a restart is recorded' {
    # A tick that records a restart observed the supervisor's token moving, not a
    # unit that was running when the probe looked, so lastLive stays put.
    Initialize-HealthRecord -Instance 'live-restart'
    Set-HealthField -Instance 'live-restart' -Field 'lastLive' -Value 7

    Add-HealthRestart -Instance 'live-restart'

    (Get-HealthField -Instance 'live-restart' -Field 'lastLive') | Should -Be 7
  }

  It 'survives the apply-time re-arm' {
    # Clear-HealthRecord is a re-arm, not a liveness observation, and
    # svc_health_clear leaves the stamp alone, so the pair stays comparable across
    # an apply.
    Initialize-HealthRecord -Instance 'live-clear'
    Set-HealthField -Instance 'live-clear' -Field 'lastLive' -Value 9

    Clear-HealthRecord -Instance 'live-clear'

    (Get-HealthField -Instance 'live-clear' -Field 'lastLive') | Should -Be 9
  }
}

Describe 'A record written before lastLive existed' {
  It 'reads the missing field as null instead of throwing' {
    Set-Content -LiteralPath (Get-HealthStateFile -Instance 'live-legacy-read') -Value $script:LegacyRecordJson -NoNewline

    { Get-HealthField -Instance 'live-legacy-read' -Field 'lastLive' } | Should -Not -Throw
    (Get-HealthField -Instance 'live-legacy-read' -Field 'lastLive') | Should -BeNullOrEmpty
  }

  It 'gains the field on the next live probe' {
    Set-Content -LiteralPath (Get-HealthStateFile -Instance 'live-legacy-write') -Value $script:LegacyRecordJson -NoNewline

    Set-HealthSuccess -Instance 'live-legacy-write'

    (Get-HealthField -Instance 'live-legacy-write' -Field 'lastLive') | Should -BeGreaterThan 0
    (Get-HealthField -Instance 'live-legacy-write' -Field 'lastSuccess') | Should -BeGreaterThan 0
  }
}
