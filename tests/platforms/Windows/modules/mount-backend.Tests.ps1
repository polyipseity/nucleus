<#
.SYNOPSIS
  Pester tests for the Windows mount backend.

.DESCRIPTION
  Mount-Backend-ProbeState is what decides whether a mount attempt SUCCEEDED.  Getting
  it wrong in the "reported dead" direction is not cosmetic: the runner retries
  `attempts` times and then leaves the service permanently blocked, so a healthy mount
  becomes an outage that only a reboot or an explicit re-arm clears.  The contract is
  four distinguishable cases - mounted-empty, mounted-non-empty, not-mounted, and a
  directory this process may not read - and these tests pin all of them, including the
  case the reparse-point union deliberately leaves alone.

  The fourth case is the reason the probe returns a token instead of a bool.  A
  directory the process is denied read access to lists as empty, so a count test
  answers "not mounted" for it and the runner reports a failure whose cause is a
  permission, not the remote.  The attach loop reads the `unknown:` prefix and stops
  blaming the remote, so the distinction is load-bearing and is asserted here rather
  than assumed.

  A reparse point stands in for a WinFsp directory mount.  PowerShell reports
  FileAttributes.ReparsePoint for a symlink on every platform, so the branch is
  exercised here as well as on a real Windows host.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/mount-backend.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../../..')
  . (Join-Path (Join-Path $repoRoot 'src/platforms/Windows/modules') 'MountBackend.ps1')
  . (Join-Path (Join-Path $repoRoot 'src/platforms/Windows/modules') 'ServiceHealth.ps1')

  # Windows-only cmdlets, absent off Windows, stubbed so Pester has a command to Mock.
  # Same shape as the stubs in svc-windows.Tests.ps1.
  function Get-Service {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    param()
    throw 'stub: Get-Service'
  }
  function Start-Service {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test stub throws; Mock supplies behavior
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    throw 'stub: Start-Service'
  }

  $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("mount-backend-$([guid]::NewGuid())")
  $script:MountedEmpty = Join-Path $script:Root 'mounted-empty'
  $script:MountedFull = Join-Path $script:Root 'mounted-full'
  $script:PlainEmpty = Join-Path $script:Root 'plain-empty'
  $script:Missing = Join-Path $script:Root 'missing'
  $script:Unreadable = Join-Path $script:Root 'unreadable'

  $target = Join-Path $script:Root 'mount-target'
  $null = New-Item -ItemType Directory -Path $target -Force
  $null = New-Item -ItemType Directory -Path $script:PlainEmpty -Force
  $null = New-Item -ItemType Directory -Path $script:MountedFull -Force
  Set-Content -Path (Join-Path $script:MountedFull 'remote-entry.txt') -Value 'x'
  $null = New-Item -ItemType Directory -Path $script:Unreadable -Force
  # An attached mount whose remote root happens to be empty.
  $null = New-Item -ItemType SymbolicLink -Path $script:MountedEmpty -Target $target

  # Block-DirectoryReadAccess — make a directory this process cannot list, and give the
  # test a way to undo it.
  #
  # WHY two implementations: POSIX denies the read bit on the directory, Windows has no
  #   such bit and needs an explicit deny ACE, and `icacls /deny` on the current user
  #   blocks the directory listing while leaving the metadata read that Get-Item needs,
  #   which is the same split the POSIX mode produces.
  # WHY read rather than read+execute: a directory needs EXECUTE to be traversed and
  #   READ to be listed, and only the listing is what the probe depends on.  Denying
  #   execute on Windows would also block the probe from reaching the directory at all.
  function Block-DirectoryReadAccess {
    param([Parameter(Mandatory)][string]$Path)

    if ($IsWindows) {
      $null = & icacls $Path /deny "$($env:USERNAME):(R)" 2>&1
      return 'icacls'
    }
    $null = & chmod 000 $Path
    return 'chmod'
  }

  # Unblock-DirectoryReadAccess — put the permissions back so the suite can delete the tree.
  function Unblock-DirectoryReadAccess {
    param(
      [Parameter(Mandatory)][string]$Path,
      [Parameter(Mandatory)][string]$Method
    )

    if ($Method -eq 'icacls') {
      $null = & icacls $Path /remove:d "$($env:USERNAME)" 2>&1
      return
    }
    $null = & chmod 700 $Path
  }

  # Get-HealthStateDir resolves $env:LOCALAPPDATA, which is empty off Windows and would
  # therefore land the record at a path relative to the CWD.  Point it at this suite's
  # temp root, and restore it in AfterAll because the Pester step runs every suite in one
  # process and a leaked value would redirect another suite's health writes.
  $script:SavedLocalAppData = $env:LOCALAPPDATA
  $env:LOCALAPPDATA = $script:Root
}

AfterAll {
  $env:LOCALAPPDATA = $script:SavedLocalAppData
  # WHY: the unreadable directory has to be made readable again before the recursive
  #   delete, or the sweep fails on the one entry it cannot list.
  if (Test-Path -LiteralPath $script:Unreadable) { Unblock-DirectoryReadAccess -Path $script:Unreadable -Method $script:DenyMethod }
  Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction Ignore
}

Describe 'Mount-Backend-ProbeState mount-state contract' {

  Context 'present' {
    It 'reports an attached mount with an empty remote root as present' {
      # The defect: a content-only test reports this healthy mount as dead, so the
      # runner retries and then blocks the service permanently.
      Mount-Backend-ProbeState -MountPoint $script:MountedEmpty | Should -BeExactly 'present'
    }

    It 'reports an attached mount with entries as present' {
      Mount-Backend-ProbeState -MountPoint $script:MountedFull | Should -BeExactly 'present'
    }
  }

  Context 'absent' {
    It 'reports a missing mount point as absent' {
      Mount-Backend-ProbeState -MountPoint $script:Missing | Should -BeExactly 'absent:not-listed'
    }

    It 'reports a plain empty directory as absent' {
      # The reparse-point union deliberately leaves this case unchanged.  The test is
      # an assumption about WinFsp, and a bare replacement would risk calling every
      # failed mount healthy, which would disable revival.
      Mount-Backend-ProbeState -MountPoint $script:PlainEmpty | Should -BeExactly 'absent:not-listed'
    }
  }

  Context 'unknown' {
    BeforeAll {
      $script:DenyMethod = Block-DirectoryReadAccess -Path $script:Unreadable
    }

    It 'reports a directory this process may not read as unknown, not as absent' {
      # Get-Item succeeds here, so the token cannot come from a null item.  It comes
      # from the listing failing, which is the only thing that separates this
      # directory from an empty one.  The runner reads the prefix and stops blaming
      # the remote, so an answer of absent here would send the operator to the wrong
      # place for a condition the process is not permitted to observe.
      Mount-Backend-ProbeState -MountPoint $script:Unreadable | Should -BeExactly 'unknown:dir-unreadable'
    }

    It 'does not confuse an unreadable directory with an empty one' {
      # The two differ only in whether the listing succeeded, and both list zero
      # entries, so this pair is what a count-based probe would collapse.
      $unreadable = Mount-Backend-ProbeState -MountPoint $script:Unreadable
      $empty = Mount-Backend-ProbeState -MountPoint $script:PlainEmpty
      $unreadable | Should -Not -Be $empty
    }
  }

  Context 'the four cases stay distinguishable' {
    It 'does not answer present for every path' {
      $answers = @(
        (Mount-Backend-ProbeState -MountPoint $script:MountedEmpty)
        (Mount-Backend-ProbeState -MountPoint $script:MountedFull)
        (Mount-Backend-ProbeState -MountPoint $script:Missing)
        (Mount-Backend-ProbeState -MountPoint $script:PlainEmpty)
      )
      $answers | Should -Contain 'present'
      $answers | Should -Contain 'absent:not-listed'
    }

    It 'emits exactly one token per call' {
      # The runner assigns the call to a variable and tests the prefix.  A second line
      # would become part of that variable and break the comparison, so the count is
      # part of the contract rather than an implementation detail.
      $answers = @(Mount-Backend-ProbeState -MountPoint $script:MountedFull)
      $answers.Count | Should -Be 1
    }
  }
}

Describe 'Mount-Backend-Mount argument list' {

  It 'starts the process with a FLAT argument list instead of a nested one' {
    # `('mount', $MountArgs)` uses the comma operator and nests the flags as one element, which
    # Start-Process rejects: "Cannot convert 'System.Object[]' to the type
    # 'System.String' required by parameter 'ArgumentList'".  Every mount attempt then
    # dies before rclone is ever started.
    $capture = Join-Path $script:Root 'capture.txt'
    $proc = Mount-Backend-Mount -RcloneBin (Get-Process -Id $PID).Path `
      -MountArgs @('-NoProfile', '-Command', 'exit 0') -CaptureFile $capture
    $proc | Should -Not -BeNullOrEmpty
    $null = $proc.WaitForExit(15000)
    $proc.HasExited | Should -BeTrue
  }
}

Describe 'Mount-Backend-Prepare failure contract' {

  BeforeEach {
    # WinFsp reported as installed, so the registry-probe branch is not taken and the
    # service check is what decides the outcome.
    Mock Get-Command -ParameterFilter { $Name -eq 'winfsp-x64.dll' } -MockWith { [pscustomobject]@{ Name = 'winfsp-x64.dll' } }
  }

  It 'reports a refused service start through the health record instead of throwing' {
    Mock Get-Service -MockWith { [pscustomobject]@{ Name = 'WinFsp.Launcher'; Status = 'Stopped' } }
    Mock Start-Service -MockWith { throw [System.UnauthorizedAccessException]::new('Access is denied.') }

    $rc = Mount-Backend-Prepare -Instance 'prepare-refused'

    # rclone-mount.ps1 has no try/catch and handles only rc 20.  An exception escaping here
    # kills the mount loop before any health record exists, leaving the watchdog a record
    # with no class or remedy to act on.
    $rc | Should -Be 20
    Should -Invoke Start-Service -Exactly 1

    $record = Get-Content -Raw (Get-HealthStateFile -Instance 'prepare-refused') | ConvertFrom-Json
    $record.state | Should -Be 'blocked'
    $record.'class' | Should -Be 'provider-refusal'
    $record.remedy | Should -Not -BeNullOrEmpty
  }

  It 'does not touch the service when the launcher is already running' {
    Mock Get-Service -MockWith { [pscustomobject]@{ Name = 'WinFsp.Launcher'; Status = 'Running' } }
    Mock Start-Service -MockWith { throw 'Start-Service must not be called' }

    $rc = Mount-Backend-Prepare -Instance 'prepare-running'

    $rc | Should -Be 0
    Should -Invoke Start-Service -Exactly 0
  }
}
