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

Describe 'Get-HealthStateFile' {
  It 'keeps a plain instance id as its own file' {
    (Get-HealthStateFile -Instance 'ollama') | Should -Be (Join-Path (Get-HealthStateDir) 'ollama.json')
  }

  It 'flattens a folder-qualified task id into one file name' {
    $path = Get-HealthStateFile -Instance '\NucleusCloudMount\NucleusCloudMount-iCloud'

    (Split-Path -Leaf $path) | Should -Be '_NucleusCloudMount_NucleusCloudMount-iCloud.json'
    (Split-Path -Parent $path) | Should -Be (Get-HealthStateDir)
  }

  It 'replaces every character that is reserved in a file name' {
    (Split-Path -Leaf (Get-HealthStateFile -Instance 'a\b/c:d*e?f"g<h>i|j')) | Should -Be 'a_b_c_d_e_f_g_h_i_j.json'
  }

  It 'writes the record at the directory root so a flat sweep reaches it' {
    Initialize-HealthRecord -Instance '\NucleusCloudMount\NucleusCloudMount-iCloud'

    @(Get-ChildItem -Path (Get-HealthStateDir) -Directory).Count | Should -Be 0
  }
}

Describe 'Clear-HealthRecord' {
  It 'returns the record to stopped so the instance is no longer blocked' {
    Set-HealthBlocked -Instance 'ollama' -Class 'crash-loop' -Remedy 'blocked'

    Clear-HealthRecord -Instance 'ollama'

    (Get-HealthField -Instance 'ollama' -Field 'state') | Should -Be 'stopped'
    (Test-HealthBlocked -Instance 'ollama') | Should -BeFalse
  }

  It 'drops class, remedy, and reportedState' {
    Set-HealthBlocked -Instance 'ollama' -Class 'crash-loop' -Remedy 'blocked'

    Clear-HealthRecord -Instance 'ollama'

    (Get-HealthField -Instance 'ollama' -Field 'class') | Should -BeNullOrEmpty
    (Get-HealthField -Instance 'ollama' -Field 'remedy') | Should -BeNullOrEmpty
    (Get-HealthField -Instance 'ollama' -Field 'reportedState') | Should -BeNullOrEmpty
  }

  It 'is a no-op for an instance with no record' {
    { Clear-HealthRecord -Instance 'never-seen' } | Should -Not -Throw
  }
}

Describe 'Clear-HealthRecordAll' {
  It 're-arms every instance, including folder-qualified task ids' {
    $instances = @('\NucleusCloudMount\NucleusCloudMount-iCloud', '\nucleus\service-watchdog', 'ollama')
    foreach ($instance in $instances) {
      Set-HealthBlocked -Instance $instance -Class 'crash-loop' -Remedy 'blocked'
    }

    Clear-HealthRecordAll

    foreach ($instance in $instances) {
      (Test-HealthBlocked -Instance $instance) | Should -BeFalse -Because "$instance must survive the apply-time re-arm"
    }
  }
}

Describe 'Re-arm drops the loop history' {
  # WHY: Test-HealthLooping reads .restarts, so a clear that kept the history would
  # leave the instance looping while unblocked, and the watchdog's Rule 3
  # (live + looping -> block + stop) would re-block it on the very next tick.  A
  # re-arm that the watchdog undoes one tick later is not a re-arm.
  BeforeEach {
    foreach ($instance in @('rearm-one', 'rearm-all')) {
      Initialize-HealthRecord -Instance $instance
      Set-HealthField -Instance $instance -Field 'restarts' -Value @(1..$script:HealthLoopRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    }
  }

  It 'starts from an instance that really is looping' {
    foreach ($instance in @('rearm-one', 'rearm-all')) {
      (Test-HealthLooping -Instance $instance) | Should -BeTrue -Because "$instance must loop before the re-arm or the assertions below are vacuous"
    }
  }

  # Each contract is its own It so that neither assertion can hide the other: a
  # failed Should throws, so two assertions in one It only ever prove the first.
  It 'leaves a Clear-HealthRecord instance un-looped' {
    Clear-HealthRecord -Instance 'rearm-one'

    (Test-HealthLooping -Instance 'rearm-one') | Should -BeFalse -Because 'Rule 3 blocks whatever this reports, so a re-armed instance must not read as looping'
  }

  It 'drops the restart history when cleared with Clear-HealthRecord' {
    Clear-HealthRecord -Instance 'rearm-one'

    (Get-HealthRestartCount -Instance 'rearm-one') | Should -Be 0 -Because 'the re-arm must drop the restart history'
  }

  It 'leaves a Clear-HealthRecordAll instance un-looped' {
    Clear-HealthRecordAll

    (Test-HealthLooping -Instance 'rearm-all') | Should -BeFalse -Because 'Rule 3 blocks whatever this reports, so the apply-time re-arm must not leave a looping record'
  }

  It 'drops the restart history when cleared with Clear-HealthRecordAll' {
    Clear-HealthRecordAll

    (Get-HealthRestartCount -Instance 'rearm-all') | Should -Be 0 -Because 'the apply-time re-arm must drop the restart history'
  }
}

# ---------------------------------------------------------------------------
# Loop-detection primitives
#
# Test-HealthLooping is the single reader of the loop thresholds, and Rule 3 of
# the watchdog blocks whatever it reports, so a counter that silently returns
# zero would leave the whole loop protection inert while every tick still
# produced a plausible answer.  These tests drive the primitives directly for
# that reason: they fail when a threshold can no longer fire, which the
# tick-level tests cannot see.
# ---------------------------------------------------------------------------

Describe 'Initialize-HealthRecord generation sentinel' {
  It 'starts at null so a stored zero stays available as a real generation' {
    Initialize-HealthRecord -Instance 'gen-fresh'

    (Get-HealthField -Instance 'gen-fresh' -Field 'generation') | Should -BeNullOrEmpty
  }

  It 'round-trips a zero generation without losing it' {
    Set-HealthField -Instance 'gen-fresh' -Field 'generation' -Value 0

    (Get-HealthField -Instance 'gen-fresh' -Field 'generation') | Should -Be 0
  }
}

Describe 'Add-HealthRestart and Get-HealthRestartCount' {
  It 'counts every recorded restart' {
    Initialize-HealthRecord -Instance 'loop-count'
    Add-HealthRestart -Instance 'loop-count'
    Add-HealthRestart -Instance 'loop-count'

    (Get-HealthRestartCount -Instance 'loop-count') | Should -Be 2
  }

  It 'prunes restarts older than an hour' {
    Initialize-HealthRecord -Instance 'loop-prune'
    Set-HealthField -Instance 'loop-prune' -Field 'restarts' -Value @([DateTimeOffset]::Now.ToUnixTimeSeconds() - 7200)

    Add-HealthRestart -Instance 'loop-prune'

    (Get-HealthRestartCount -Instance 'loop-prune') | Should -Be 1
  }

  It 'reports zero for an instance that has no record' {
    (Get-HealthRestartCount -Instance 'loop-absent') | Should -Be 0
  }
}

Describe 'Set-HealthSuccess and Get-HealthConsecutiveFailureCount' {
  It 'counts every restart as consecutive before any success' {
    Initialize-HealthRecord -Instance 'loop-consec'
    Add-HealthRestart -Instance 'loop-consec'
    Add-HealthRestart -Instance 'loop-consec'
    Add-HealthRestart -Instance 'loop-consec'

    (Get-HealthConsecutiveFailureCount -Instance 'loop-consec') | Should -Be 3
  }

  It 'clears the consecutive count once a success is recorded' {
    Set-HealthSuccess -Instance 'loop-consec'

    (Get-HealthField -Instance 'loop-consec' -Field 'lastSuccess') | Should -BeGreaterThan 0
    (Get-HealthConsecutiveFailureCount -Instance 'loop-consec') | Should -Be 0
  }

  It 'reports zero for an instance that has no record' {
    (Get-HealthConsecutiveFailureCount -Instance 'loop-absent') | Should -Be 0
  }
}

Describe 'Test-HealthLooping thresholds' {
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
    Initialize-HealthRecord -Instance 'loop-neg'
    Set-HealthField -Instance 'loop-neg' -Field 'restarts' -Value @(1..($script:HealthLoopConsecutive - 1) | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })

    (Test-HealthLooping -Instance 'loop-neg') | Should -BeFalse
  }

  It 'loops when the consecutive-failure rule alone trips' {
    Initialize-HealthRecord -Instance 'loop-cons-hit'
    Set-HealthField -Instance 'loop-cons-hit' -Field 'restarts' -Value @(1..$script:HealthLoopConsecutive | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })

    (Get-HealthRestartCount -Instance 'loop-cons-hit') | Should -BeLessThan $script:HealthLoopRestarts
    (Test-HealthLooping -Instance 'loop-cons-hit') | Should -BeTrue
  }

  It 'loops when the hourly rule alone trips' {
    Initialize-HealthRecord -Instance 'loop-hour-hit'
    Set-HealthField -Instance 'loop-hour-hit' -Field 'restarts' -Value @(1..$script:HealthLoopRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    # A success newer than every restart empties the consecutive rule, which
    # leaves the hourly count as the only rule able to fire.
    Set-HealthField -Instance 'loop-hour-hit' -Field 'lastSuccess' -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds() + 60)

    (Get-HealthConsecutiveFailureCount -Instance 'loop-hour-hit') | Should -Be 0
    (Test-HealthLooping -Instance 'loop-hour-hit') | Should -BeTrue
  }

  It 'does not loop one restart below the hourly threshold' {
    Initialize-HealthRecord -Instance 'loop-hour-neg'
    Set-HealthField -Instance 'loop-hour-neg' -Field 'restarts' -Value @(1..($script:HealthLoopRestarts - 1) | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    Set-HealthField -Instance 'loop-hour-neg' -Field 'lastSuccess' -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds() + 60)

    (Test-HealthLooping -Instance 'loop-hour-neg') | Should -BeFalse
  }
}

Describe 'Get-HealthStatus' {
  It 'reports OK below the warning threshold' {
    Initialize-HealthRecord -Instance 'status-ok'

    (Get-HealthStatus -Instance 'status-ok') | Should -Be 'OK'
  }

  It 'reports the hourly rate at the warning threshold' {
    Initialize-HealthRecord -Instance 'status-warn'
    Set-HealthField -Instance 'status-warn' -Field 'restarts' -Value @(1..$script:HealthWarnRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })
    Set-HealthField -Instance 'status-warn' -Field 'lastSuccess' -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds() + 60)

    (Get-HealthStatus -Instance 'status-warn') | Should -Be "$($script:HealthWarnRestarts)/hr"
  }

  It 'reports LOOP exactly when the looping predicate is true' {
    Initialize-HealthRecord -Instance 'status-loop'
    Set-HealthField -Instance 'status-loop' -Field 'restarts' -Value @(1..$script:HealthLoopRestarts | ForEach-Object { [DateTimeOffset]::Now.ToUnixTimeSeconds() })

    (Test-HealthLooping -Instance 'status-loop') | Should -BeTrue
    (Get-HealthStatus -Instance 'status-loop') | Should -Be 'LOOP'
  }
}

Describe 'Set-HealthRunning and Set-HealthLastExitCode' {
  It 'clears the blocker fields and marks the instance running' {
    Set-HealthBlocked -Instance 'run-state' -Class 'crash-loop' -Remedy 'blocked'

    Set-HealthRunning -Instance 'run-state'

    (Get-HealthField -Instance 'run-state' -Field 'state') | Should -Be 'running'
    (Get-HealthField -Instance 'run-state' -Field 'class') | Should -BeNullOrEmpty
    (Get-HealthField -Instance 'run-state' -Field 'remedy') | Should -BeNullOrEmpty
    (Test-HealthBlocked -Instance 'run-state') | Should -BeFalse
  }

  It 'records the last exit code so a repair can classify it' {
    Initialize-HealthRecord -Instance 'run-state'

    Set-HealthLastExitCode -Instance 'run-state' 78

    (Get-HealthField -Instance 'run-state' -Field 'lastExit') | Should -Be 78
  }
}

Describe 'Test-HealthReported and Set-HealthReported' {
  It 'reports a state only once it has been marked' {
    Set-HealthBlocked -Instance 'reported-state' -Class 'crash-loop' -Remedy 'blocked'

    (Test-HealthReported -Instance 'reported-state' -Expected 'blocked') | Should -BeFalse

    Set-HealthReported -Instance 'reported-state' -State 'blocked'

    (Test-HealthReported -Instance 'reported-state' -Expected 'blocked') | Should -BeTrue
    (Test-HealthReported -Instance 'reported-state' -Expected 'not-loaded') | Should -BeFalse
  }

  It 'drops the reported state when a fresh block replaces it' {
    Set-HealthReported -Instance 'reported-state' -State 'blocked'

    Set-HealthBlocked -Instance 'reported-state' -Class 'crash-loop' -Remedy 'blocked'

    (Test-HealthReported -Instance 'reported-state' -Expected 'blocked') | Should -BeFalse
  }
}

Describe 'Get-HealthBootId boot identity' {
  # Get-HealthBootId must ASK THE OS on every call.  It previously cached the answer
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
    $first = Get-HealthBootId

    $script:StubBootTime = [datetime]'2026-09-20T09:00:00'
    $second = Get-HealthBootId

    $first | Should -Not -Be $second -Because 'a cached identity cannot change across a reboot'
  }

  It 'writes no sticky boot-id cache file' {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'

    Get-HealthBootId > $null

    (Test-Path (Join-Path (Get-HealthStateDir) '.boot-id')) | Should -BeFalse
  }

  It 'clears a block once the OS reports a new boot' {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'
    Set-HealthBlocked -Instance 'boot-reboot' -Class 'crash-loop' -Remedy 'blocked'
    (Test-HealthBlocked -Instance 'boot-reboot') | Should -BeTrue -Because 'the block was set during this boot'

    $script:StubBootTime = [datetime]'2026-09-20T09:00:00'

    (Test-HealthBlocked -Instance 'boot-reboot') | Should -BeFalse -Because 'a reboot clears the block'
    (Get-HealthField -Instance 'boot-reboot' -Field 'state') | Should -Be 'blocked'
  }

  It 'keeps a block when the OS cannot report a boot time' {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'
    Set-HealthBlocked -Instance 'boot-fail-closed' -Class 'crash-loop' -Remedy 'blocked'

    $script:StubBootTime = $null

    (Get-HealthBootId) | Should -Be 'unknown'
    (Test-HealthBlocked -Instance 'boot-fail-closed') | Should -BeTrue -Because 'an unavailable boot source is not evidence of a reboot'
  }

  AfterAll {
    $script:StubBootTime = [datetime]'2026-09-19T16:17:08'
  }
}
