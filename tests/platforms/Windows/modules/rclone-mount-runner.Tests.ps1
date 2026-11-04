<#
.SYNOPSIS
  Contract tests for the minimal Windows cloud-mount supervisor.

.DESCRIPTION
  Pins the wrapper contract shared with rclone-mount.sh: launch rclone with
  the instance's arguments verbatim, stream its output into the retained
  mount log, and start again after any exit on the configured cadence. There
  are no health records and no classification by design; the loop and the
  log file are the whole supervision surface.

  The loop runs forever, so every loop case runs the wrapper in a child
  process, polls for the observable it needs, and kills the child. Exit-code
  and looping behavior are never tested through in-process invocation.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/rclone-mount-runner.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../../..')
  $script:Runner = Join-Path $repoRoot 'src/scripts/services/rclone-mount.ps1'
  $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("rclone-mount-$([guid]::NewGuid())")
  $null = New-Item -ItemType Directory -Path $script:Root -Force

  # Save-StandInRclone: an executable that stands in for rclone. Each
  # invocation appends one block to the shared invocation log (a marker
  # line, then what the process received), writes the chosen stderr lines,
  # and exits with the chosen code.
  #
  # WHY two implementations: Start-Process runs a file, not a command line,
  #   so the stand-in must be executable on the host: a shebang script on
  #   POSIX and a .cmd on Windows.
  # WHY the argv shapes differ: on POSIX the recorded block is one line per
  #   argv element, which proves element-level verbatim forwarding. cmd has
  #   no verbatim argv loop, so the Windows block is the raw %* remainder
  #   with PowerShell's own quoting, which is exactly the command line rclone
  #   would receive.

  # Write-StandInRcloneCmd: write the Windows stand-in batch file, one command
  # per line.
  #
  # WHY the parenthesized -f: inside an array literal, -f applies to the whole
  #   array expression, so @('@echo off', 'echo ...' -f $x) yields ONE element
  #   '@echo off echo ...'. cmd then runs 'echo' with the arguments 'off echo
  #   ...', echo is never turned off, and the command echo repeats the marker
  #   text into the invocation log before any attempt has finished. The block
  #   splitter finds a second block inside the first attempt, the suite stops
  #   the supervisor before it retries, and both the retry notice and the
  #   recorded argv assertions fail on artifacts instead of on the supervisor.
  # WHY the bytes are written here, not by Set-Content: the suite asserts the
  #   generated command boundaries on every host, so the fixture must produce the
  #   same bytes everywhere instead of inheriting a platform newline default.
  function Write-StandInRcloneCmd {
    param(
      [Parameter(Mandatory)][string]$Path,
      [Parameter(Mandatory)][string]$InvocationLog,
      [int]$ExitCode = 1,
      [string[]]$Stderr = @('stand-in rclone failure')
    )

    $lines = @('@echo off', ('echo === invocation>>"{0}"' -f $InvocationLog))
    foreach ($line in $Stderr) { $lines += 'echo {0} 1>&2' -f $line }
    $lines += 'echo %* >>"{0}"' -f $InvocationLog
    $lines += 'exit /b {0}' -f $ExitCode
    [System.IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
    return $Path
  }

  function Save-StandInRclone {
    param(
      [Parameter(Mandatory)][string]$BinDir,
      [Parameter(Mandatory)][string]$InvocationLog,
      [int]$ExitCode = 1,
      [string[]]$Stderr = @('stand-in rclone failure')
    )

    $null = New-Item -ItemType Directory -Path $BinDir -Force
    if ($IsWindows) {
      return Write-StandInRcloneCmd -Path (Join-Path $BinDir 'rclone.cmd') `
        -InvocationLog $InvocationLog -ExitCode $ExitCode -Stderr $Stderr
    }

    $path = Join-Path $BinDir 'rclone'
    # WHY the log path travels through a sibling file read at run time
    #   ($0.LOG): a baked-in absolute path would have to be shell-quoted twice
    #   (generator and script), while the sibling keeps quoting to one place.
    Set-Content -Path "$path.LOG" -Value $InvocationLog
    $body = @(
      '#!/bin/sh'
      'LOG="$(cat "$0.LOG")"'
      'printf "%s\\n" "=== invocation" >>"$LOG"'
      'for _a in "$@"; do printf "arg:%s\\n" "$_a" >>"$LOG"; done'
    )
    foreach ($line in $Stderr) {
      $escaped = $line.Replace("'", "'\''")
      $body += "printf '%s\n' '$escaped' >&2"
    }
    $body += 'exit {0}' -f $ExitCode
    Set-Content -Path $path -Value ($body -join "`n")
    $null = & chmod 755 $path
    return $path
  }

  # Get-InvocationBlockList: split the invocation log into per-attempt blocks.
  function Get-InvocationBlockList {
    param([Parameter(Mandatory)][string]$InvocationLog)
    if (-not (Test-Path -LiteralPath $InvocationLog)) { return @() }
    $raw = Get-Content -Raw -LiteralPath $InvocationLog
    $blocks = @()
    foreach ($chunk in ($raw -split '=== invocation')) {
      if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
      # WHY the prefix strip: the POSIX stand-in records one arg: line per
      # argv element, while the Windows stand-in records the raw %* line
      # (unchanged here); stripping keeps blocks argv-shaped on both hosts.
      $lines = @($chunk -split "`n" | ForEach-Object { $_.TrimEnd("`r") } |
        Where-Object { $_ -ne '' } |
        ForEach-Object { $_ -replace '^arg:', '' })
      $blocks += ,$lines
    }
    # WHY the extra comma wrap: a bare `return $blocks` writes an array to the
    # pipeline, which enumerates it, and a single-block result then collapses
    # to that block's line items; the caller would read three lines as three
    # attempts and kill the wrapper before the log flushed. The wrap emits the
    # block array itself as one object for zero, one, or many blocks.
    return ,$blocks
  }

  # Save-LaunchDriver: generate the per-case launcher script.
  #
  # WHY a driver instead of pwsh -File directly on the wrapper: -File mode
  # binds exactly one command-line element to a string[] parameter and rejects
  # repeats, so multi-flag arguments cannot travel that way on any platform.
  # Production calls the wrapper in-process from the generated mount-<id>.ps1
  # with a real array, so the driver is also the production call shape.
  function Save-LaunchDriver {
    param(
      [Parameter(Mandatory)][string]$Path,
      [Parameter(Mandatory)][string]$Runner,
      [Parameter(Mandatory)][string]$LogFile,
      [Parameter(Mandatory)][string]$MountPoint,
      [Parameter(Mandatory)][string]$RemoteSpec,
      [string[]]$FlagArgs = @(),
      [int]$RetrySeconds = 30
    )

    $quote = { param($value) "'" + ([string]$value).Replace("'", "''") + "'" }
    $flags = if ($FlagArgs.Count -gt 0) {
      '@(' + (($FlagArgs | ForEach-Object { & $quote $_ }) -join ', ') + ')'
    } else {
      '@()'
    }
    $text = @(
      '$ErrorActionPreference = ''Stop'''
      ('& {0} -Instance ''local.cloud-mount.test'' -LogFile {1} -MountPoint {2} -RemoteSpec {3} -RcloneArgs {4} -RetrySeconds {5}' -f `
          (& $quote $Runner), (& $quote $LogFile), (& $quote $MountPoint), `
          (& $quote $RemoteSpec), $flags, $RetrySeconds)
    )
    Set-Content -Path $Path -Value ($text -join "`n")
    return $Path
  }

  # Wait-Until: poll a condition for a bounded time; false on timeout.
  function Wait-Until {
    param(
      [Parameter(Mandatory)][scriptblock]$Condition,
      [int]$TimeoutSeconds = 12
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
      if (& $Condition) { return $true }
      Start-Sleep -Milliseconds 250
    }
    return (& $Condition)
  }

  # Start-Supervisor: launch the wrapper in a child process and track it for
  # the suite-wide kill sweep.
  function Start-Supervisor {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test helper that spawns a child under the suite temp tree; -WhatIf would break every case that needs a live process
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    # WHY the quoting pass: Start-Process joins -ArgumentList into a single
    # command string without quoting on every platform, so a value with
    # spaces (the repo path itself, the spaced mount point) would split into
    # stray argv elements; the child's parser reassembles each
    # double-quoted value into one argument.
    $quoted = @($ArgumentList | ForEach-Object {
        if ($_ -match '[ \t]') { '"{0}"' -f $_ } else { $_ }
      })
    # WHY script scope: a case reads the captured stdout while the child is
    #   still running, so the path has to outlive this helper.
    $script:SupervisorStdoutPath = Join-Path $script:Root 'supervisor-stdout.log'
    $stdoutPath = $script:SupervisorStdoutPath
    $stderrPath = Join-Path $script:Root 'supervisor-stderr.log'
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path `
      -ArgumentList $quoted `
      -PassThru `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath
    $script:StartedProcs += $proc
    return $proc
  }

  # Stop-Supervisor: kill a tracked child so no loop outlives its case.
  function Stop-Supervisor {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test helper that kills only the child the suite spawned; a WhatIf guard would leave loops running past the case
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    $Process.Kill()
    $null = $Process.WaitForExit(5000)
  }

  # Invoke-MissingParameter: run the wrapper without the given parameters and
  # return the child's outcome. -NonInteractive is required: mandatory
  # parameters would otherwise prompt, and a prompt would hang the suite.
  # WHY no Mandatory on -ArgumentList: the no-argument case under test IS an
  # empty list, which a Mandatory parameter rejects before pwsh ever runs.
  function Invoke-MissingParameter {
    param([string[]]$ArgumentList = @())

    $output = & pwsh -NoProfile -NonInteractive -File $script:Runner @ArgumentList 2>&1
    return @{ Output = ($output | Out-String); ExitCode = $LASTEXITCODE }
  }

  $script:StartedProcs = @()
}

AfterAll {
  foreach ($proc in $script:StartedProcs) {
    try {
      if (-not $proc.HasExited) { $proc.Kill() }
    } catch {
      # A process that exits between the check and the kill needs no sweep;
      # the remaining processes are still cleaned up below.
      Write-Verbose "supervisor process already gone: $($_.Exception.Message)"
    }
  }
  Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction Ignore
}

Describe 'rclone-mount.ps1 minimal supervisor contract' {

  It 'fails loudly when mandatory parameters are missing' {
    $none = Invoke-MissingParameter -ArgumentList @()
    $none.ExitCode | Should -Not -Be 0
    $none.Output | Should -Match 'missing mandatory parameters'
    $none.Output | Should -Match 'Instance'
    $none.Output | Should -Match 'LogFile'

    $partial = Invoke-MissingParameter -ArgumentList @('-Instance', 'local.cloud-mount.test')
    $partial.ExitCode | Should -Not -Be 0
    $partial.Output | Should -Match 'missing mandatory parameters'
    $partial.Output | Should -Match 'LogFile'
    $partial.Output | Should -Not -Match 'Instance'
  }

  It 'writes the Windows stand-in with one command per line' {
    $path = Write-StandInRcloneCmd -Path (Join-Path $script:Root 'stand-in.cmd') `
      -InvocationLog (Join-Path $script:Root 'invocations.log') -ExitCode 1 -Stderr @('probe-error-line')
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $loneLf = 0
    for ($i = 0; $i -lt $bytes.Count; $i++) {
      if ($bytes[$i] -ne 0x0a) { continue }
      if ($i -eq 0 -or $bytes[$i - 1] -ne 0x0d) { $loneLf++ }
    }
    $loneLf | Should -Be 0
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $commandLines = @($text -split "`r`n")
    $commandLines[0] | Should -Be '@echo off'
    $commandLines[1] | Should -Match '^echo === invocation>>"'
  }

  It 'invokes rclone again after a failed exit and keeps its stderr in the mount log' {
    $caseRoot = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
    $invLog = Join-Path $caseRoot 'invocations.log'
    $binDir = Join-Path $caseRoot 'bin'
    $mountLog = Join-Path -Path $caseRoot -ChildPath 'logs' -AdditionalChildPath 'mount.log'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force
    $null = Save-StandInRclone -BinDir $binDir -InvocationLog $invLog `
      -ExitCode 1 -Stderr @('probe-error-line')
    $driver = Save-LaunchDriver -Path (Join-Path $caseRoot 'launch.ps1') `
      -Runner $script:Runner -LogFile $mountLog `
      -MountPoint (Join-Path $caseRoot 'mnt') -RemoteSpec 'testremote:' `
      -RetrySeconds 1
    $launchArgs = @('-NoProfile', '-NonInteractive', '-File', $driver)
    $envPath = $binDir + [IO.Path]::PathSeparator + $env:PATH
    $prevPath = $env:PATH
    $env:PATH = $envPath
    try {
      $proc = Start-Supervisor -ArgumentList $launchArgs
      $secondAttempt = Wait-Until -Condition {
        (Get-InvocationBlockList -InvocationLog $invLog).Count -ge 2
      } -TimeoutSeconds 15
      # WHY before the kill: the notice exists only after an attempt has exited,
      #   so waiting for it observes the retry itself; a notice written after the
      #   delay would still appear, which the separate pre-sleep case rules out.
      $retryNotice = Wait-Until -Condition {
        (Test-Path -LiteralPath $script:SupervisorStdoutPath) -and
        ((Get-Content -Raw -LiteralPath $script:SupervisorStdoutPath) -match 'retrying in 1s')
      } -TimeoutSeconds 15
      Stop-Supervisor -Process $proc
    } finally {
      $env:PATH = $prevPath
    }

    $secondAttempt | Should -BeTrue
    $retryNotice | Should -BeTrue
    (Get-InvocationBlockList -InvocationLog $invLog).Count | Should -BeGreaterOrEqual 2
    Test-Path -LiteralPath $mountLog | Should -BeTrue
    (Get-Content -Raw -LiteralPath $mountLog) | Should -Match 'probe-error-line'
    $stdout = Get-Content -Raw -LiteralPath $script:SupervisorStdoutPath
    $stdout | Should -Match 'retrying in 1s'
  }

  It 'writes the retry notice before the retry delay elapses' {
    $caseRoot = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
    $invLog = Join-Path $caseRoot 'invocations.log'
    $binDir = Join-Path $caseRoot 'bin'
    $mountLog = Join-Path $caseRoot 'mount.log'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force
    $null = Save-StandInRclone -BinDir $binDir -InvocationLog $invLog -ExitCode 1
    # WHY 30 s against a 10 s wait: the notice has to appear while the delay is
    #   still running, so a write after Start-Sleep cannot satisfy this case.
    $driver = Save-LaunchDriver -Path (Join-Path $caseRoot 'launch.ps1') `
      -Runner $script:Runner -LogFile $mountLog `
      -MountPoint (Join-Path $caseRoot 'mnt') -RemoteSpec 'testremote:' `
      -RetrySeconds 30
    $launchArgs = @('-NoProfile', '-NonInteractive', '-File', $driver)
    $envPath = $binDir + [IO.Path]::PathSeparator + $env:PATH
    $prevPath = $env:PATH
    $env:PATH = $envPath
    try {
      $proc = Start-Supervisor -ArgumentList $launchArgs
      $notice = Wait-Until -Condition {
        (Test-Path -LiteralPath $script:SupervisorStdoutPath) -and
        ((Get-Content -Raw -LiteralPath $script:SupervisorStdoutPath) -match 'retrying in 30s')
      } -TimeoutSeconds 10
      $attempts = (Get-InvocationBlockList -InvocationLog $invLog).Count
      Stop-Supervisor -Process $proc
    } finally {
      $env:PATH = $prevPath
    }

    $notice | Should -BeTrue
    $attempts | Should -Be 1
  }

  It 'forwards the remote spec, a mount point with spaces, and every flag verbatim' {
    $caseRoot = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
    $invLog = Join-Path $caseRoot 'invocations.log'
    $binDir = Join-Path $caseRoot 'bin'
    $mountLog = Join-Path $caseRoot 'mount.log'
    $spacedMount = Join-Path $caseRoot 'cloud dir with spaces'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force
    $null = New-Item -ItemType Directory -Path $spacedMount -Force
    $null = Save-StandInRclone -BinDir $binDir -InvocationLog $invLog -ExitCode 1
    $flagArgs = @('--volname', 'Cloud Drive', '--read-only')
    $driver = Save-LaunchDriver -Path (Join-Path $caseRoot 'launch.ps1') `
      -Runner $script:Runner -LogFile $mountLog `
      -MountPoint $spacedMount -RemoteSpec 'testremote:' `
      -FlagArgs $flagArgs -RetrySeconds 600
    $launchArgs = @('-NoProfile', '-NonInteractive', '-File', $driver)

    $envPath = $binDir + [IO.Path]::PathSeparator + $env:PATH
    $prevPath = $env:PATH
    $env:PATH = $envPath
    try {
      $proc = Start-Supervisor -ArgumentList $launchArgs
      $firstAttempt = Wait-Until -Condition {
        (Get-InvocationBlockList -InvocationLog $invLog).Count -ge 1
      } -TimeoutSeconds 12
      Stop-Supervisor -Process $proc
    } finally {
      $env:PATH = $prevPath
    }

    $firstAttempt | Should -BeTrue
    $block = (Get-InvocationBlockList -InvocationLog $invLog)[0]
    if ($IsWindows) {
      # cmd records the raw %* command line: tokens with spaces carry the
      # quotes PowerShell emitted, which is the command line rclone receives.
      $block.Count | Should -Be 1
      $block[0] | Should -Match ([regex]::Escape('testremote:'))
      $block[0] | Should -Match ([regex]::Escape('"{0}"' -f $spacedMount))
      $block[0] | Should -Match ([regex]::Escape('"Cloud Drive"'))
      $block[0] | Should -Match ([regex]::Escape('--read-only'))
    } else {
      # The first argv element of the stand-in is the subcommand 'mount',
      # because the wrapper invokes `rclone mount <remote> <point> [flags]`.
      # Joined before comparing: the Pester pipeline unrolls an array on the
      # left of -Be, which would compare each element against the whole array.
      $expected = @('mount', 'testremote:', $spacedMount) + @('--volname', 'Cloud Drive', '--read-only')
      ($block -join "`n") | Should -Be ($expected -join "`n")
    }
  }

  It 'creates the log directory before the first attempt' {
    $caseRoot = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
    $invLog = Join-Path $caseRoot 'invocations.log'
    $binDir = Join-Path $caseRoot 'bin'
    $mountLog = Join-Path -Path $caseRoot -ChildPath 'deep' -AdditionalChildPath 'nested', 'mount.log'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force
    $null = Save-StandInRclone -BinDir $binDir -InvocationLog $invLog -ExitCode 1
    $driver = Save-LaunchDriver -Path (Join-Path $caseRoot 'launch.ps1') `
      -Runner $script:Runner -LogFile $mountLog `
      -MountPoint (Join-Path $caseRoot 'mnt') -RemoteSpec 'testremote:' `
      -RetrySeconds 600
    $launchArgs = @('-NoProfile', '-NonInteractive', '-File', $driver)
    $envPath = $binDir + [IO.Path]::PathSeparator + $env:PATH
    $prevPath = $env:PATH
    $env:PATH = $envPath
    try {
      $proc = Start-Supervisor -ArgumentList $launchArgs
      $oneAttempt = Wait-Until -Condition {
        (Get-InvocationBlockList -InvocationLog $invLog).Count -ge 1
      } -TimeoutSeconds 12
      Stop-Supervisor -Process $proc
    } finally {
      $env:PATH = $prevPath
    }

    $oneAttempt | Should -BeTrue
    Test-Path -LiteralPath $mountLog | Should -BeTrue
  }
}
