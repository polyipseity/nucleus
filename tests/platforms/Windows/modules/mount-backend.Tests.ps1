<#
.SYNOPSIS
  Pester tests for the Windows mount backend.

.DESCRIPTION
  Mount-Backend-Probe is what decides whether a mount attempt SUCCEEDED.  Getting it
  wrong in the "reported dead" direction is not cosmetic: the runner retries
  `attempts` times and then leaves the service permanently blocked, so a healthy mount
  becomes an outage that only a reboot or an explicit re-arm clears.  The contract is
  three distinguishable cases - mounted-empty, mounted-non-empty, not-mounted - and
  these tests pin all of them, including the case the union deliberately leaves alone.

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

  $target = Join-Path $script:Root 'mount-target'
  $null = New-Item -ItemType Directory -Path $target -Force
  $null = New-Item -ItemType Directory -Path $script:PlainEmpty -Force
  $null = New-Item -ItemType Directory -Path $script:MountedFull -Force
  Set-Content -Path (Join-Path $script:MountedFull 'remote-entry.txt') -Value 'x'
  # An attached mount whose remote root happens to be empty.
  $null = New-Item -ItemType SymbolicLink -Path $script:MountedEmpty -Target $target

  # Get-HealthStateDir resolves $env:LOCALAPPDATA, which is empty off Windows and would
  # therefore land the record at a path relative to the CWD.  Point it at this suite's
  # temp root, and restore it in AfterAll because the Pester step runs every suite in one
  # process and a leaked value would redirect another suite's health writes.
  $script:SavedLocalAppData = $env:LOCALAPPDATA
  $env:LOCALAPPDATA = $script:Root
}

AfterAll {
  $env:LOCALAPPDATA = $script:SavedLocalAppData
  Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction Ignore
}

Describe 'Mount-Backend-Probe mount-state contract' {

  Context 'mounted' {
    It 'reports an attached mount with an empty remote root as mounted' {
      # The defect: a content-only test reports this healthy mount as dead, so the
      # runner retries and then blocks the service permanently.
      Mount-Backend-Probe -MountPoint $script:MountedEmpty | Should -BeTrue
    }

    It 'reports an attached mount with entries as mounted' {
      Mount-Backend-Probe -MountPoint $script:MountedFull | Should -BeTrue
    }
  }

  Context 'not mounted' {
    It 'reports a missing mount point as not mounted' {
      Mount-Backend-Probe -MountPoint $script:Missing | Should -BeFalse
    }

    It 'reports a plain empty directory as not mounted' {
      # The union deliberately leaves this case unchanged.  The reparse-point test is
      # an assumption about WinFsp, and a bare replacement would risk calling every
      # failed mount healthy, which would disable revival.
      Mount-Backend-Probe -MountPoint $script:PlainEmpty | Should -BeFalse
    }
  }

  Context 'the three cases stay distinguishable' {
    It 'does not answer mounted for every path' {
      $answers = @(
        (Mount-Backend-Probe -MountPoint $script:MountedEmpty)
        (Mount-Backend-Probe -MountPoint $script:MountedFull)
        (Mount-Backend-Probe -MountPoint $script:Missing)
        (Mount-Backend-Probe -MountPoint $script:PlainEmpty)
      )
      $answers | Should -Contain $true
      $answers | Should -Contain $false
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
