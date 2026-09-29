<#
.SYNOPSIS
  Pester tests for the cloud-mount runner's required lifecycle inputs (D50).

.DESCRIPTION
  The retry policy (mountAttempts, mountRetryBackoffSeconds, mountAttachTimeoutSeconds) is
  single-sourced from
  cloud-drive.lifecycle in services.json, and the Windows generator injects it as
  NUCLEUS_MOUNT_ATTEMPTS / NUCLEUS_MOUNT_BACKOFF / NUCLEUS_MOUNT_ATTACH_SECONDS.
  The POSIX runner consumes the same three with `:?` — required, no fallback.

  A default in the runner is therefore a SECOND policy definition that can drift
  from the registry, which is what this file pins: a missing value must fail
  loudly and name the variable, and a present value must actually be consumed.

  Every case throws before the runner reaches the health record or the mount
  backend, so these tests perform no mount and write no state. LOCALAPPDATA
  still points at a temp tree, because the health root resolves from it.

  The retry-loop cases below do reach the backend, and they need one: the runner
  resolves its modules from $NUCLEUS_REPO_ROOT, so the suite points that at a
  fixture repo root whose MountBackend.ps1 loads the real backend and stubs only
  Mount-Backend-Prepare, whose WinFsp registry and service lookups do not exist
  off Windows and would otherwise end every run at "backend requires user action"
  before the attach loop. The probe and the failure classifier under test are the
  production implementations, and the mount itself is a stand-in rclone that writes
  a chosen message to stderr and exits.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/rclone-mount-runner.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../../..')
  $script:Runner = Join-Path $repoRoot 'src/scripts/services/rclone-mount.ps1'
  $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("rclone-runner-$([guid]::NewGuid())")
  $null = New-Item -ItemType Directory -Path (Join-Path $script:Root 'la') -Force

  # Inputs every case shares, so the failure under test is the one reported.
  $script:BaseEnv = @{
    NUCLEUS_REPO_ROOT                  = $repoRoot.Path
    LOCALAPPDATA                       = (Join-Path $script:Root 'la')
    NUCLEUS_CLOUD_MOUNT_INSTANCE       = 'local.cloud-mount.iCloud'
    NUCLEUS_RCLONE_REMOTE              = 'iCloud:/'
    NUCLEUS_RCLONE_MOUNT_POINT         = (Join-Path $script:Root 'mnt')
  }
  $script:LifecycleNames = @(
    'NUCLEUS_MOUNT_ATTEMPTS'
    'NUCLEUS_MOUNT_ATTACH_SECONDS'
    'NUCLEUS_MOUNT_BACKOFF'
  )

  # Invoke-Runner — run the real runner in a CHILD process with a controlled
  # environment. A child is required: the runner is a script, not a function
  # module, and the throw must be observed as the process outcome.
  function Invoke-Runner {
    param([hashtable]$Env = @{})

    $saved = @{}
    foreach ($name in $script:LifecycleNames) {
      $saved[$name] = [Environment]::GetEnvironmentVariable($name)
      [Environment]::SetEnvironmentVariable($name, $null)
    }
    try {
      foreach ($name in $Env.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$Env[$name]) }
      $output = & pwsh -NoProfile -File $script:Runner 2>&1
      return @{ Output = ($output | Out-String); ExitCode = $LASTEXITCODE }
    } finally {
      foreach ($name in $script:LifecycleNames) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
      }
    }
  }

  function New-CaseEnv {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- Pester helper that merges two hashtables; it mutates no system state and the New- verb reads as "make a case env"
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([hashtable]$Extra = @{})
    $env = @{}
    foreach ($k in $script:BaseEnv.Keys) { $env[$k] = $script:BaseEnv[$k] }
    foreach ($k in $Extra.Keys) { $env[$k] = $Extra[$k] }
    return $env
  }

  # MountFixtureRoot — the repo root whose modules dir the runner loads.
  $script:FixtureRoot = Join-Path -Path $repoRoot.Path -ChildPath 'tests/fixtures/windows-mount-runner/repo'

  # Save-StandInRclone — an executable that stands in for rclone.
  #
  # WHY two implementations: Start-Process runs a file, not a command line, so the
  #   stand-in has to be something the host can execute — a shebang script on POSIX, a
  #   .cmd on Windows. Both write one line to stderr, which is what the classifier
  #   reads, and both exit 1, which is what a mount that never attaches does.
  # WHY MarkerName: the stand-in writes the marker into the mount point it is handed
  #   on the command line, so the name is all it needs to know. The runner prepends the
  #   'mount' subcommand, so the mount point is the third argument after the program
  #   name: $0 is this file, $1 is 'mount', $2 is the remote, $3 is the mount point.
  function Save-StandInRclone {
    param(
      [Parameter(Mandatory)][string]$Stderr,
      [string]$MarkerName = ''
    )

    $path = Join-Path -Path $script:CaseRoot -ChildPath 'stand-in-rclone'
    if ($IsWindows) {
      $path = "$path.cmd"
      $lines = @('@echo off', ('echo {0} 1>&2' -f $Stderr))
      if ($MarkerName) { $lines += ('type nul > "%~3\{0}"' -f $MarkerName) }
      $lines += 'exit /b 1'
      Set-Content -Path $path -Value $lines
      return $path
    }

    $lines = @('#!/bin/sh', ('echo {0} >&2' -f "'$Stderr'"))
    if ($MarkerName) { $lines += ('touch "{0}/{1}"' -f '$3', $MarkerName) }
    $lines += 'exit 1'
    Set-Content -Path $path -Value $lines
    $null = & chmod 755 $path
    return $path
  }

  # Invoke-MountAttempt — run the real runner against the fixture backend.
  function Invoke-MountAttempt {
    param([hashtable]$Extra = @{})

    $env = New-CaseEnv @{
      NUCLEUS_REPO_ROOT            = $script:FixtureRoot
      LOCALAPPDATA                 = (Join-Path -Path $script:CaseRoot -ChildPath 'la')
      NUCLEUS_RCLONE_MOUNT_POINT   = $script:MountPoint
      NUCLEUS_RCLONE_BIN           = $script:StandIn
      NUCLEUS_MOUNT_ATTACH_SECONDS = '5'
      NUCLEUS_MOUNT_BACKOFF        = '1'
      # WHY TEMP is supplied: the runner writes its stderr capture to $env:TEMP, which
      #   Windows always defines and PowerShell on a POSIX host does not. Pointing it
      #   into the case root also puts the capture file where the case can clean it up.
      TEMP                         = $script:CaseRoot
    }
    foreach ($k in $Extra.Keys) { $env[$k] = $Extra[$k] }

    # WHY save, set, restore: the runner is a script rather than a function, so its
    # inputs have to arrive through the environment the child process inherits. A
    # lifecycle name the case did not supply is cleared first, for the same reason
    # Invoke-Runner clears them above, so a value another case left in this process
    # cannot reach the run.
    $saved = @{}
    foreach ($k in $env.Keys) {
      $saved[$k] = [Environment]::GetEnvironmentVariable($k)
      [Environment]::SetEnvironmentVariable($k, [string]$env[$k])
    }
    foreach ($name in $script:LifecycleNames) {
      if (-not $env.ContainsKey($name)) { [Environment]::SetEnvironmentVariable($name, $null) }
    }
    try {
      $output = & pwsh -NoProfile -File $script:Runner 2>&1
      $exitCode = $LASTEXITCODE
    } finally {
      foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }

    return @{
      Output   = ($output | Out-String)
      ExitCode = $exitCode
      Record   = if (Test-Path -LiteralPath $script:RecordPath) {
        Get-Content -Raw -LiteralPath $script:RecordPath | ConvertFrom-Json
      } else { $null }
    }
  }
}

AfterAll {
  Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction Ignore
}

Describe 'rclone-mount.ps1 requires the injected lifecycle policy' {

  It 'fails loudly when NUCLEUS_MOUNT_ATTEMPTS is unset' {
    $result = Invoke-Runner -Env (New-CaseEnv)
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'NUCLEUS_MOUNT_ATTEMPTS not set'
  }

  It 'fails loudly when NUCLEUS_MOUNT_ATTACH_SECONDS is unset' {
    $result = Invoke-Runner -Env (New-CaseEnv @{ NUCLEUS_MOUNT_ATTEMPTS = '1' })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'NUCLEUS_MOUNT_ATTACH_SECONDS not set'
  }

  It 'fails loudly when NUCLEUS_MOUNT_BACKOFF is unset' {
    $result = Invoke-Runner -Env (New-CaseEnv @{
        NUCLEUS_MOUNT_ATTEMPTS        = '1'
        NUCLEUS_MOUNT_ATTACH_SECONDS  = '0'
      })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'NUCLEUS_MOUNT_BACKOFF not set'
  }

  It 'consumes the injected attempts value instead of defaulting it' {
    # A non-numeric value must fail at the conversion: reaching an Int32 cast
    # proves the injected value is what the runner parses, and that no default
    # silently replaced it.
    $result = Invoke-Runner -Env (New-CaseEnv @{
        NUCLEUS_MOUNT_ATTEMPTS        = 'notanumber'
        NUCLEUS_MOUNT_ATTACH_SECONDS  = '0'
        NUCLEUS_MOUNT_BACKOFF         = '1'
      })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'System.Int32'
    $result.Output | Should -Not -Match 'NUCLEUS_MOUNT_ATTEMPTS not set'
  }

  It 'consumes the injected backoff value instead of defaulting it' {
    $result = Invoke-Runner -Env (New-CaseEnv @{
        NUCLEUS_MOUNT_ATTEMPTS        = '1'
        NUCLEUS_MOUNT_ATTACH_SECONDS  = '0'
        NUCLEUS_MOUNT_BACKOFF         = 'notanumber'
      })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'System.Int32'
    $result.Output | Should -Not -Match 'NUCLEUS_MOUNT_BACKOFF not set'
  }
}

Describe 'rclone-mount.ps1 retry loop' {

  BeforeEach {
    $script:CaseRoot = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $script:CaseRoot 'la') -Force
    $script:MountPoint = Join-Path $script:CaseRoot 'mnt'
    $null = New-Item -ItemType Directory -Path $script:MountPoint -Force
    $script:RecordPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $script:CaseRoot 'la') 'nucleus') 'state') 'service-stats') 'local.cloud-mount.iCloud.json'
  }

  AfterEach {
    if (Test-Path -LiteralPath $script:MountPoint) { $null = & chmod 700 $script:MountPoint }
    Remove-Item -LiteralPath $script:CaseRoot -Recurse -Force -ErrorAction Ignore
  }

  Context 'attempts exhausted' {

    It 'blocks with the last attempt own class rather than a fixed mount-failed' {
      # The last attempt's rclone output classifies as io-transient, so the exhausted
      # record must say io-transient. A hardcoded mount-failed discards the only
      # classification the run produced and sends the operator to the remote when what
      # stopped the run was a transient network failure.
      $script:StandIn = Save-StandInRclone -Stderr 'connection refused'
      $result = Invoke-MountAttempt -Extra @{ NUCLEUS_MOUNT_ATTEMPTS = '2' }

      $result.ExitCode | Should -Be 0
      $result.Record.state | Should -Be 'blocked'
      $result.Record.'class' | Should -Be 'io-transient'
      $result.Record.remedy | Should -Be 'retry in progress'
    }

    It 'reports the attempt that failed on its own classification' {
      $script:StandIn = Save-StandInRclone -Stderr 'connection refused'
      $result = Invoke-MountAttempt -Extra @{ NUCLEUS_MOUNT_ATTEMPTS = '2' }

      $result.Output | Should -Match 'attempt 1 failed \(class=io-transient'
      $result.Output | Should -Match 'attempt 2 failed \(class=io-transient'
    }
  }

  Context 'mount point this process may not read' {

    BeforeEach {
      $null = & chmod 000 $script:MountPoint
    }

    It 'blocks as io-transient rather than reporting the classifier diagnosis' {
      # The mount point cannot be listed, so the probe cannot say whether the mount
      # is there. The classifier's answer comes from rclone's output, which is about
      # a different question; a terminal class from it would stop the run and point
      # the operator at the remote on the strength of a read that never completed.
      $script:StandIn = Save-StandInRclone -Stderr 'rclone: VFS cache unusable'
      $result = Invoke-MountAttempt -Extra @{ NUCLEUS_MOUNT_ATTEMPTS = '1' }

      $result.Record.state | Should -Be 'blocked'
      $result.Record.'class' | Should -Be 'io-transient'
    }

    It 'keeps the capture file and records where it is' {
      # The class here is one the runner chose, not one rclone's output supports, so
      # the file is the only remaining record of what the mount was doing. The path
      # goes in the record because log lines rotate.
      $script:StandIn = Save-StandInRclone -Stderr 'rclone: VFS cache unusable'
      $result = Invoke-MountAttempt -Extra @{ NUCLEUS_MOUNT_ATTEMPTS = '1' }

      $result.Record.evidence | Should -Not -BeNullOrEmpty
      Test-Path -LiteralPath $result.Record.evidence | Should -BeTrue
      Get-Content -Raw -LiteralPath $result.Record.evidence | Should -Match 'VFS cache unusable'
      $result.Output | Should -Match ([regex]::Escape('rclone output kept at'))
    }
  }

  Context 'a known diagnosis' {

    It 'drops the capture file and leaves no evidence pointer' {
      # The guard for the case above: retention belongs to the unreadable mount point
      # alone, and a class rclone's output supports is the whole diagnosis, so the
      # file has nothing left to say.
      $script:StandIn = Save-StandInRclone -Stderr 'Unauthorized'
      $result = Invoke-MountAttempt -Extra @{ NUCLEUS_MOUNT_ATTEMPTS = '3' }

      $result.Record.'class' | Should -Be 'auth'
      $result.Record.PSObject.Properties.Name | Should -Not -Contain 'evidence'
      $result.Output | Should -Not -Match 'rclone output kept at'
    }

    It 'stops on the first attempt for a terminal class' {
      $script:StandIn = Save-StandInRclone -Stderr 'Unauthorized'
      $result = Invoke-MountAttempt -Extra @{ NUCLEUS_MOUNT_ATTEMPTS = '3' }

      $result.Output | Should -Match 'attempt 1 failed \(class=auth'
      $result.Output | Should -Not -Match 'attempt 2 failed'
    }
  }

  Context 'a mount that attaches' {

    It 'leaves the evidence key present and null so a healthy mount reads as healthy' {
      # Reaching running ends the failure the pointer was written for. The key is
      # cleared to null rather than dropped, so a healthy mount reads as a key with no
      # value, not as a key that was never there.
      $script:StandIn = Save-StandInRclone -Stderr 'mounted' -MarkerName 'attached.txt'
      $result = Invoke-MountAttempt -Extra @{ NUCLEUS_MOUNT_ATTEMPTS = '1' }

      $result.Record.state | Should -Be 'running'
      $result.Record.PSObject.Properties.Name | Should -Contain 'evidence'
      $result.Record.evidence | Should -BeNullOrEmpty
    }
  }
}
