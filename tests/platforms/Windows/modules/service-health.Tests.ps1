<#
.SYNOPSIS
  Pester tests for the Windows service health record.

.DESCRIPTION
  The health record is the single source of truth shared by the watchdog on every
  host, so its storage path and its re-arm semantics must hold for every instance
  id shape the registry can produce.  Scheduled-task ids are folder-qualified
  (\Folder\Name), which is the shape that breaks a naive file-name mapping and a
  flat re-arm sweep.

  Get-CimInstance is stubbed because boot-id lookup is the only WMI dependency,
  so the suite runs on macOS and Linux as well as Windows.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/service-health.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $modulesDir = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules'
  . (Join-Path $modulesDir 'ServiceHealth.ps1')

  if (-not (Get-Command -Name 'Get-CimInstance' -ErrorAction Ignore)) {
    Set-Item -Path 'Function:Get-CimInstance' -Value {
      param([string]$ClassName)
      # The stub models the one class the boot-id lookup uses and fails loudly for
      # any other, so a future caller cannot silently receive a wrong answer.
      if ($ClassName -ne 'Win32_OperatingSystem') { throw "stub: unexpected class $ClassName" }
      [PSCustomObject]@{ LastBootUpTime = [datetime]'2026-09-19T16:17:08' }
    }
  }

  # A per-run root keeps records out of the real user profile.
  $script:OriginalLocalAppData = $env:LOCALAPPDATA
  $script:HealthRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("service-health-{0}" -f [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $script:HealthRoot -Force > $null
  $env:LOCALAPPDATA = $script:HealthRoot
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

Describe 'Health-StateFile' {
  It 'keeps a plain instance id as its own file' {
    (Health-StateFile -Instance 'ollama') | Should -Be (Join-Path (Health-StateDir) 'ollama.json')
  }

  It 'flattens a folder-qualified task id into one file name' {
    $path = Health-StateFile -Instance '\NucleusCloudMount\NucleusCloudMount-iCloud'

    (Split-Path -Leaf $path) | Should -Be '_NucleusCloudMount_NucleusCloudMount-iCloud.json'
    (Split-Path -Parent $path) | Should -Be (Health-StateDir)
  }

  It 'replaces every character that is reserved in a file name' {
    (Split-Path -Leaf (Health-StateFile -Instance 'a\b/c:d*e?f"g<h>i|j')) | Should -Be 'a_b_c_d_e_f_g_h_i_j.json'
  }

  It 'writes the record at the directory root so a flat sweep reaches it' {
    Health-Init -Instance '\NucleusCloudMount\NucleusCloudMount-iCloud'

    @(Get-ChildItem -Path (Health-StateDir) -Directory).Count | Should -Be 0
  }
}

Describe 'Health-Clear' {
  It 'returns the record to stopped so the instance is no longer blocked' {
    Health-SetBlocked -Instance 'ollama' -Class 'crash-loop' -Remedy 'blocked'

    Health-Clear -Instance 'ollama'

    (Health-Get -Instance 'ollama' -Field 'state') | Should -Be 'stopped'
    (Health-IsBlocked -Instance 'ollama') | Should -BeFalse
  }

  It 'drops class, remedy, and reportedState' {
    Health-SetBlocked -Instance 'ollama' -Class 'crash-loop' -Remedy 'blocked'

    Health-Clear -Instance 'ollama'

    (Health-Get -Instance 'ollama' -Field 'class') | Should -BeNullOrEmpty
    (Health-Get -Instance 'ollama' -Field 'remedy') | Should -BeNullOrEmpty
    (Health-Get -Instance 'ollama' -Field 'reportedState') | Should -BeNullOrEmpty
  }

  It 'is a no-op for an instance with no record' {
    { Health-Clear -Instance 'never-seen' } | Should -Not -Throw
  }
}

Describe 'Health-ClearAll' {
  It 're-arms every instance, including folder-qualified task ids' {
    $instances = @('\NucleusCloudMount\NucleusCloudMount-iCloud', '\nucleus\service-watchdog', 'ollama')
    foreach ($instance in $instances) {
      Health-SetBlocked -Instance $instance -Class 'crash-loop' -Remedy 'blocked'
    }

    Health-ClearAll

    foreach ($instance in $instances) {
      (Health-IsBlocked -Instance $instance) | Should -BeFalse -Because "$instance must survive the apply-time re-arm"
    }
  }
}

Describe 'Re-arm drops the loop history' {
  # WHY: Health-IsLooping reads .restarts, so a clear that kept the history would
  # leave the instance looping while unblocked, and the watchdog's Rule 3
  # (live + looping -> block + stop) would re-block it on the very next tick.  A
  # re-arm that the watchdog undoes one tick later is not a re-arm.
  BeforeEach {
    foreach ($instance in @('rearm-one', 'rearm-all')) {
      Health-Init -Instance $instance
      Health-Set -Instance $instance -Field 'restarts' -Value @(1..$script:HealthLoopRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    }
  }

  It 'starts from an instance that really is looping' {
    foreach ($instance in @('rearm-one', 'rearm-all')) {
      (Health-IsLooping -Instance $instance) | Should -BeTrue -Because "$instance must loop before the re-arm or the assertions below are vacuous"
    }
  }

  # Each contract is its own It so that neither assertion can hide the other: a
  # failed Should throws, so two assertions in one It only ever prove the first.
  It 'leaves a Health-Clear instance un-looped' {
    Health-Clear -Instance 'rearm-one'

    (Health-IsLooping -Instance 'rearm-one') | Should -BeFalse -Because 'Rule 3 blocks whatever this reports, so a re-armed instance must not read as looping'
  }

  It 'drops the restart history when cleared with Health-Clear' {
    Health-Clear -Instance 'rearm-one'

    (Health-RestartCount -Instance 'rearm-one') | Should -Be 0 -Because 'the re-arm must drop the restart history'
  }

  It 'leaves a Health-ClearAll instance un-looped' {
    Health-ClearAll

    (Health-IsLooping -Instance 'rearm-all') | Should -BeFalse -Because 'Rule 3 blocks whatever this reports, so the apply-time re-arm must not leave a looping record'
  }

  It 'drops the restart history when cleared with Health-ClearAll' {
    Health-ClearAll

    (Health-RestartCount -Instance 'rearm-all') | Should -Be 0 -Because 'the apply-time re-arm must drop the restart history'
  }
}

# ---------------------------------------------------------------------------
# Loop-detection primitives
#
# Health-IsLooping is the single reader of the loop thresholds, and Rule 3 of
# the watchdog blocks whatever it reports, so a counter that silently returns
# zero would leave the whole loop protection inert while every tick still
# produced a plausible answer.  These tests drive the primitives directly for
# that reason: they fail when a threshold can no longer fire, which the
# tick-level tests cannot see.
# ---------------------------------------------------------------------------

Describe 'Health-Init generation sentinel' {
  It 'starts at null so a stored zero stays available as a real generation' {
    Health-Init -Instance 'gen-fresh'

    (Health-Get -Instance 'gen-fresh' -Field 'generation') | Should -BeNullOrEmpty
  }

  It 'round-trips a zero generation without losing it' {
    Health-Set -Instance 'gen-fresh' -Field 'generation' -Value 0

    (Health-Get -Instance 'gen-fresh' -Field 'generation') | Should -Be 0
  }
}

Describe 'Health-RecordRestart and Health-RestartCount' {
  It 'counts every recorded restart' {
    Health-Init -Instance 'loop-count'
    Health-RecordRestart -Instance 'loop-count'
    Health-RecordRestart -Instance 'loop-count'

    (Health-RestartCount -Instance 'loop-count') | Should -Be 2
  }

  It 'prunes restarts older than an hour' {
    Health-Init -Instance 'loop-prune'
    Health-Set -Instance 'loop-prune' -Field 'restarts' -Value @([DateTimeOffset]::Now.ToUnixTimeSeconds() - 7200)

    Health-RecordRestart -Instance 'loop-prune'

    (Health-RestartCount -Instance 'loop-prune') | Should -Be 1
  }

  It 'reports zero for an instance that has no record' {
    (Health-RestartCount -Instance 'loop-absent') | Should -Be 0
  }
}

Describe 'Health-RecordSuccess and Health-ConsecutiveFailures' {
  It 'counts every restart as consecutive before any success' {
    Health-Init -Instance 'loop-consec'
    Health-RecordRestart -Instance 'loop-consec'
    Health-RecordRestart -Instance 'loop-consec'
    Health-RecordRestart -Instance 'loop-consec'

    (Health-ConsecutiveFailures -Instance 'loop-consec') | Should -Be 3
  }

  It 'clears the consecutive count once a success is recorded' {
    Health-RecordSuccess -Instance 'loop-consec'

    (Health-Get -Instance 'loop-consec' -Field 'lastSuccess') | Should -BeGreaterThan 0
    (Health-ConsecutiveFailures -Instance 'loop-consec') | Should -Be 0
  }

  It 'reports zero for an instance that has no record' {
    (Health-ConsecutiveFailures -Instance 'loop-absent') | Should -Be 0
  }
}

Describe 'Health-IsLooping thresholds' {
  # WHY: the boundaries are derived from the thresholds themselves instead of
  # being restated, so this suite cannot drift away from the policy it guards.
  # The relations below are what make the isolating cases valid: a distinct
  # consecutive threshold lets it trip alone, and a warn threshold at or below
  # the hourly one keeps the warn case from already reading as a loop.
  It 'keeps the thresholds in their required relation' {
    $script:HealthLoopConsecutive | Should -BeLessThan $script:HealthLoopRestarts
    $script:HealthWarnRestarts | Should -BeLessOrEqual $script:HealthLoopRestarts
  }

  It 'does not loop one consecutive failure below the threshold' {
    Health-Init -Instance 'loop-neg'
    Health-Set -Instance 'loop-neg' -Field 'restarts' -Value @(1..($script:HealthLoopConsecutive - 1) | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })

    (Health-IsLooping -Instance 'loop-neg') | Should -BeFalse
  }

  It 'loops when the consecutive-failure rule alone trips' {
    Health-Init -Instance 'loop-cons-hit'
    Health-Set -Instance 'loop-cons-hit' -Field 'restarts' -Value @(1..$script:HealthLoopConsecutive | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })

    (Health-RestartCount -Instance 'loop-cons-hit') | Should -BeLessThan $script:HealthLoopRestarts
    (Health-IsLooping -Instance 'loop-cons-hit') | Should -BeTrue
  }

  It 'loops when the hourly rule alone trips' {
    Health-Init -Instance 'loop-hour-hit'
    Health-Set -Instance 'loop-hour-hit' -Field 'restarts' -Value @(1..$script:HealthLoopRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    # A success newer than every restart empties the consecutive rule, which
    # leaves the hourly count as the only rule able to fire.
    Health-Set -Instance 'loop-hour-hit' -Field 'lastSuccess' -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds() + 60)

    (Health-ConsecutiveFailures -Instance 'loop-hour-hit') | Should -Be 0
    (Health-IsLooping -Instance 'loop-hour-hit') | Should -BeTrue
  }

  It 'does not loop one restart below the hourly threshold' {
    Health-Init -Instance 'loop-hour-neg'
    Health-Set -Instance 'loop-hour-neg' -Field 'restarts' -Value @(1..($script:HealthLoopRestarts - 1) | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    Health-Set -Instance 'loop-hour-neg' -Field 'lastSuccess' -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds() + 60)

    (Health-IsLooping -Instance 'loop-hour-neg') | Should -BeFalse
  }
}

Describe 'Health-Status' {
  It 'reports OK below the warning threshold' {
    Health-Init -Instance 'status-ok'

    (Health-Status -Instance 'status-ok') | Should -Be 'OK'
  }

  It 'reports the hourly rate at the warning threshold' {
    Health-Init -Instance 'status-warn'
    Health-Set -Instance 'status-warn' -Field 'restarts' -Value @(1..$script:HealthWarnRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    Health-Set -Instance 'status-warn' -Field 'lastSuccess' -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds() + 60)

    (Health-Status -Instance 'status-warn') | Should -Be "$($script:HealthWarnRestarts)/hr"
  }

  It 'reports LOOP exactly when the looping predicate is true' {
    Health-Init -Instance 'status-loop'
    Health-Set -Instance 'status-loop' -Field 'restarts' -Value @(1..$script:HealthLoopRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })

    (Health-IsLooping -Instance 'status-loop') | Should -BeTrue
    (Health-Status -Instance 'status-loop') | Should -Be 'LOOP'
  }
}

Describe 'Health-SetRunning and Health-SetLastExit' {
  It 'clears the blocker fields and marks the instance running' {
    Health-SetBlocked -Instance 'run-state' -Class 'crash-loop' -Remedy 'blocked'

    Health-SetRunning -Instance 'run-state'

    (Health-Get -Instance 'run-state' -Field 'state') | Should -Be 'running'
    (Health-Get -Instance 'run-state' -Field 'class') | Should -BeNullOrEmpty
    (Health-Get -Instance 'run-state' -Field 'remedy') | Should -BeNullOrEmpty
    (Health-IsBlocked -Instance 'run-state') | Should -BeFalse
  }

  It 'records the last exit code so a repair can classify it' {
    Health-Init -Instance 'run-state'

    Health-SetLastExit -Instance 'run-state' 78

    (Health-Get -Instance 'run-state' -Field 'lastExit') | Should -Be 78
  }
}

Describe 'Health-IsReported and Health-MarkReported' {
  It 'reports a state only once it has been marked' {
    Health-SetBlocked -Instance 'reported-state' -Class 'crash-loop' -Remedy 'blocked'

    (Health-IsReported -Instance 'reported-state' -Expected 'blocked') | Should -BeFalse

    Health-MarkReported -Instance 'reported-state' -State 'blocked'

    (Health-IsReported -Instance 'reported-state' -Expected 'blocked') | Should -BeTrue
    (Health-IsReported -Instance 'reported-state' -Expected 'not-loaded') | Should -BeFalse
  }

  It 'drops the reported state when a fresh block replaces it' {
    Health-MarkReported -Instance 'reported-state' -State 'blocked'

    Health-SetBlocked -Instance 'reported-state' -Class 'crash-loop' -Remedy 'blocked'

    (Health-IsReported -Instance 'reported-state' -Expected 'blocked') | Should -BeFalse
  }
}

Describe 'Health-BootId boot identity' {
  # Health-BootId must ASK THE OS on every call.  It previously cached the answer
  # in the state dir's .boot-id file and read it back forever, so the value could
  # not change across a reboot and the documented reboot-clears-a-block path was
  # unreachable.  Only the OS probe is stubbed here — a test cannot reboot the
  # host — and every other line runs the real implementation.
  #
  # One stub, driven by a variable, so there is a single definition and the two
  # boots differ solely in their value.  A null value models an OS that cannot
  # report a boot time at all.
  BeforeAll {
    $script:StubBootTime = $null
    Set-Item -Path 'Function:Get-CimInstance' -Value {
      param([string]$ClassName)
      if ($ClassName -ne 'Win32_OperatingSystem') { throw "stub: unexpected class $ClassName" }
      if ($null -eq $script:StubBootTime) { throw 'stub: the OS cannot report a boot time' }
      [PSCustomObject]@{ LastBootUpTime = $script:StubBootTime }
    }
  }

  It 'follows the OS boot time rather than a cached value' {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'
    $first = Health-BootId

    $script:StubBootTime = [datetime]'2026-09-20T09:00:00'
    $second = Health-BootId

    $first | Should -Not -Be $second -Because 'a cached identity cannot change across a reboot'
  }

  It 'writes no sticky boot-id cache file' {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'

    Health-BootId > $null

    (Test-Path (Join-Path (Health-StateDir) '.boot-id')) | Should -BeFalse
  }

  It 'clears a block once the OS reports a new boot' {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'
    Health-SetBlocked -Instance 'boot-reboot' -Class 'crash-loop' -Remedy 'blocked'
    (Health-IsBlocked -Instance 'boot-reboot') | Should -BeTrue -Because 'the block was set during this boot'

    $script:StubBootTime = [datetime]'2026-09-20T09:00:00'

    (Health-IsBlocked -Instance 'boot-reboot') | Should -BeFalse -Because 'a reboot clears the block'
    (Health-Get -Instance 'boot-reboot' -Field 'state') | Should -Be 'blocked'
  }

  It 'keeps a block when the OS cannot report a boot time' {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'
    Health-SetBlocked -Instance 'boot-fail-closed' -Class 'crash-loop' -Remedy 'blocked'

    $script:StubBootTime = $null

    (Health-BootId) | Should -Be 'unknown'
    (Health-IsBlocked -Instance 'boot-fail-closed') | Should -BeTrue -Because 'an unavailable boot source is not evidence of a reboot'
  }

  AfterAll {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'
  }
}
