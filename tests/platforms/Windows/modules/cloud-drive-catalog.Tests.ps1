<#
.SYNOPSIS
  Pester tests for the Windows cloud-drive mount catalog generator.

.DESCRIPTION
  Sync-CloudDriveCatalog generates the per-mount wrapper the logon scheduled task
  runs, and registers the task with bounded restart-on-failure settings. The wrapper
  is the only place the instance id, mount point, remote spec, and rclone argument
  array are decided, and every one of them is consumed in a DIFFERENT scope from the
  one that produced it: the wrapper runs later, in a fresh process, with no access
  to the $mount hashtable.

  These tests therefore assert on the GENERATED FILE, not on the generator's local
  variables.  A value that is merely correct in the generator's scope but not written
  into the wrapper is invisible until a real mount fails at logon.

  The Windows-only ScheduledTasks cmdlets are stubbed, and rclone is shimmed on PATH,
  so the real generator runs end to end on macOS and Linux as well as Windows.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/cloud-drive-catalog.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../../..')
  $modulesDir = Join-Path $repoRoot 'src/platforms/Windows/modules'

  $script:OriginalLocalAppData = $env:LOCALAPPDATA
  $script:OriginalLogDir = $env:NUCLEUS_LOG_DIR
  $script:OriginalRepoRoot = $env:NUCLEUS_REPO_ROOT
  $script:OriginalPath = $env:PATH

  # A per-run root keeps generated wrappers and health records out of the real profile.
  $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("cloud-drive-catalog-{0}" -f [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $script:Root -Force > $null
  $script:UserHome = Join-Path $script:Root 'home'
  New-Item -ItemType Directory -Path $script:UserHome -Force > $null

  $env:LOCALAPPDATA = Join-Path $script:Root 'LocalAppData'
  New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force > $null
  $env:NUCLEUS_LOG_DIR = Join-Path $script:Root 'logs'
  New-Item -ItemType Directory -Path $env:NUCLEUS_LOG_DIR -Force > $null
  # The generator resolves the shared runner and services.json through this.
  $env:NUCLEUS_REPO_ROOT = $repoRoot

  # rclone is shimmed rather than stubbed: the generator resolves it with Get-Command
  # and invokes it, so a PowerShell function would not be found (it reads .Source).
  $script:ShimDir = Join-Path $script:Root 'shim'
  New-Item -ItemType Directory -Path $script:ShimDir -Force > $null
  if ($IsWindows) {
    Set-Content -Path (Join-Path $script:ShimDir 'rclone.cmd') -Value "@echo iCloud:`r`n@echo OneDrive:`r`n"
  }
  else {
    $shim = Join-Path $script:ShimDir 'rclone'
    Set-Content -Path $shim -Value "#!/bin/sh`nif [ `"`$1`" = 'listremotes' ]; then echo 'iCloud:'; echo 'OneDrive:'; fi`nexit 0`n"
    & chmod '+x' $shim
  }
  $env:PATH = $script:ShimDir + [IO.Path]::PathSeparator + $env:PATH

  Import-Module (Join-Path $modulesDir 'Format-NucleusOutput.psm1') -Force -DisableNameChecking
  . (Join-Path $modulesDir 'Invoke-LogManagement.ps1')
  . (Join-Path $modulesDir 'Get-NucleusServiceInstance.ps1')
  . (Join-Path $modulesDir 'user/Sync-CloudDriveCatalog.ps1')

  # ScheduledTasks is a Windows-only module; the generator calls these before and after
  # writing the wrapper.  Stubs keep the wrapper write on the real code path.
  # WHY the suppressions below: these are test doubles, not cmdlets.  Each shadows a real
  # ScheduledTasks cmdlet under its exact name: that name IS the shadowing mechanism, so it
  # cannot be renamed away, and each returns a [pscustomobject] without touching system
  # state.  Their parameters exist only so the stub signature matches how
  # Sync-CloudDriveCatalog calls the real cmdlet, which PSScriptAnalyzer cannot see across
  # the file boundary (the documented PSReviewUnusedParameter limitation).
  function New-ScheduledTaskAction {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test double shadowing a real cmdlet; the New- name is required to shadow it and it changes no system state
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- parameter mirrors the real cmdlet's signature; the cross-file call site is invisible to the rule
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([string]$Execute, [string]$Argument)
    [pscustomobject]@{ Execute = $Execute }
  }
  function New-ScheduledTaskTrigger {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test double shadowing a real cmdlet; the New- name is required to shadow it and it changes no system state
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- parameter mirrors the real cmdlet's signature; the cross-file call site is invisible to the rule
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([switch]$AtLogOn, [string]$User)
    [pscustomobject]@{ User = $User }
  }
  function New-ScheduledTaskSettingsSet {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test double shadowing a real cmdlet; the New- name is required to shadow it and it changes no system state
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- parameters mirror the real cmdlet's signature; the cross-file call site is invisible to the rule
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, [int]$RestartCount, [TimeSpan]$RestartInterval, [TimeSpan]$ExecutionTimeLimit)
    [pscustomobject]@{ RestartCount = $RestartCount; RestartInterval = $RestartInterval; ExecutionTimeLimit = $ExecutionTimeLimit }
  }
  function New-ScheduledTaskPrincipal {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test double shadowing a real cmdlet; the New- name is required to shadow it and it changes no system state
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- parameter mirrors the real cmdlet's signature; the cross-file call site is invisible to the rule
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([string]$UserId, [string]$RunLevel)
    [pscustomobject]@{ UserId = $UserId }
  }
  function Register-ScheduledTask {
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- parameters mirror the real cmdlet's signature; the cross-file call site is invisible to the rule
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([string]$TaskName, [string]$TaskPath, $Action, $Trigger, $Settings, $Principal, [switch]$Force)
    $script:LastRegisteredSettings = $Settings
    [pscustomobject]@{ TaskName = $TaskName }
  }
  function Get-ScheduledTask {
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- parameters mirror the real cmdlet's signature; the cross-file call site is invisible to the rule
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([string]$TaskName, [string]$TaskPath)
    $null
  }
  function Unregister-ScheduledTask {
    # check-suppress:SuppressMessageAttribute: PSUseSupportsShouldProcess -- the stub mirrors the real cmdlet's -Confirm surface so production call sites bind unchanged; SupportsShouldProcess would add ShouldProcess machinery a test double has no use for
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '')]
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- parameters mirror the real cmdlet's signature; the cross-file call site is invisible to the rule
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([string]$TaskName, [switch]$Confirm)
  }

  # One read-only and one read-write mount: the read-only branch is only observable
  # by comparison, so both directions are generated in the same run.
  $config = @{
    cloudDrives = @{
      mounts   = @(
        @{ id = 'iCloud'; enable = $true; localPath = 'clouds/iCloud'; remoteName = 'iCloud'; remotePath = '/'; readWrite = $true },
        @{ id = 'OneDrive'; enable = $true; localPath = 'clouds/OneDrive'; remoteName = 'OneDrive'; remotePath = '/'; readWrite = $false }
      )
      replicas = @()
    }
  }
  Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome

  $script:WrapperDir = Join-Path $env:LOCALAPPDATA 'nucleus/cloud-drive'
  $script:Wrapper = @{}
  foreach ($id in 'iCloud', 'OneDrive') {
    # The generator writes CRLF (the file runs on Windows).  Normalize so the
    # multiline patterns below are not defeated by the carriage return.
    $script:Wrapper[$id] = (Get-Content -Raw (Join-Path $script:WrapperDir "mount-$id.ps1")) -replace "`r`n", "`n"
  }
  $script:Registry = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') | ConvertFrom-Json -AsHashtable
}

AfterAll {
  foreach ($pair in @(
      @{ Name = 'LOCALAPPDATA'; Value = $script:OriginalLocalAppData },
      @{ Name = 'NUCLEUS_LOG_DIR'; Value = $script:OriginalLogDir },
      @{ Name = 'NUCLEUS_REPO_ROOT'; Value = $script:OriginalRepoRoot },
      @{ Name = 'PATH'; Value = $script:OriginalPath })) {
    if ($null -eq $pair.Value) { Remove-Item "Env:$($pair.Name)" -ErrorAction Ignore }
    else { Set-Item "Env:$($pair.Name)" $pair.Value }
  }
  Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction Ignore
}

Describe 'Sync-CloudDriveCatalog generated wrapper' {

  Context 'D47 - mount point' {
    It 'passes the mount point the runner requires, not an empty value' {
      # An empty mount point fails the mount at logon in a hidden window, so the
      # named parameter must always carry the per-mount local path.
      foreach ($id in 'iCloud', 'OneDrive') {
        $match = [regex]::Match($script:Wrapper[$id], "-MountPoint '([^']*)'")
        $match.Success | Should -BeTrue -Because "the wrapper for $id must pass the mount point"
        $match.Groups[1].Value | Should -Not -BeNullOrEmpty -Because "$id must not carry an empty mount point"
        $match.Groups[1].Value | Should -Be (Join-Path $script:UserHome "clouds/$id") -Because 'the mount point is the per-mount local path'
      }
    }
  }

  Context 'D48 - read-only is resolved at generation time' {
    It 'marks a read-only mount read-only' {
      [regex]::Match($script:Wrapper['OneDrive'], '-RcloneArgs (@\(.*?\))').Groups[1].Value |
        Should -Match "'--read-only'" -Because 'OneDrive declares readWrite false'
    }

    It 'marks a read-write mount writable' {
      [regex]::Match($script:Wrapper['iCloud'], '-RcloneArgs (@\(.*?\))').Groups[1].Value |
        Should -Not -Match "'--read-only'" -Because 'iCloud declares readWrite true'
    }

    It 'writes the array as a literal, not a deferred expression' {
      # The wrapper runs in a fresh process with no $mount hashtable. A deferred
      # conditional would silently evaluate to writable for every mount. The
      # generated text is checked for the sub-expression itself: interpolating
      # $mount.<prop> inside the generator's string expands it there, so searching
      # for a variable reference would never match and the assertion could not fail.
      foreach ($id in 'iCloud', 'OneDrive') {
        $line = [regex]::Match($script:Wrapper[$id], '(?m)^.*-RcloneArgs .*$').Value
        $line | Should -Not -Match '\$\(' -Because "$id must resolve the array at generation time"
      }
    }
  }

  Context 'D45 - instance id matches the watchdog mapping' {
    It 'passes the folder-qualified instance id the watchdog resolves' {
      # The watchdog discovers a declared-but-not-running instance through this
      # same task-folder mapping, so a mismatched id makes the instance invisible.
      $entry = $script:Registry['cloud-drive'].hosts.Windows
      $watchdogId = Get-NucleusInstanceId -TaskFolder ([string]$entry.taskPath) -TaskName "$($entry.service)iCloud"
      $emitted = [regex]::Match($script:Wrapper['iCloud'], "-Instance '([^']*)'").Groups[1].Value
      $emitted | Should -Be $watchdogId -Because 'a mismatched id makes the watchdog unable to discover the declared instance'
    }
  }

  Context 'D46 - no runner retry policy, restart-on-failure instead' {
    It 'emits no retry environment the deleted runner used to read' {
      # The retry cadence belongs to the platform manager: the wrapper's loop
      # sleeps 30 seconds between attempts and the task settings revive a pwsh
      # process that died. Nothing reads a per-attempt budget anymore.
      foreach ($id in 'iCloud', 'OneDrive') {
        $script:Wrapper[$id] | Should -Not -Match 'NUCLEUS_MOUNT_ATTEMPTS' -Because "$id must not resurrect the deleted runner contract"
        $script:Wrapper[$id] | Should -Not -Match 'NUCLEUS_MOUNT_BACKOFF' -Because "$id must not resurrect the deleted runner contract"
        $script:Wrapper[$id] | Should -Not -Match 'NUCLEUS_CLOUD_MOUNT_INSTANCE' -Because "$id must not resurrect the deleted health-record contract"
      }
    }

    It 'registers the task with bounded restart-on-failure settings' {
      # The task-level restart only revives a pwsh process that died, so the
      # count is bounded: a permanently broken install must not restart forever,
      # and the loop in the wrapper owns the fast cadence on its own.
      $script:LastRegisteredSettings | Should -Not -BeNullOrEmpty
      $script:LastRegisteredSettings.RestartCount | Should -Be 10
      $script:LastRegisteredSettings.RestartInterval | Should -Be ([TimeSpan]::FromMinutes(1))
      $script:LastRegisteredSettings.ExecutionTimeLimit | Should -Be ([TimeSpan]::Zero)
    }
  }

  Context 'D59 - the argument array carries the base set and the extras' {
    It 'carries the base five, the per-mount flags, and the extras' {
      # The canonical fixture has no provider or extraArgs, so an absence check
      # against it would pass for the wrong reason. This generates a mount that
      # DOES have extras, so the value under test exercises both halves.
      $providerConfig = @{
        cloudDrives = @{
          mounts   = @(
            @{ id = 'iCloud'; enable = $true; localPath = 'clouds/iCloud'; remoteName = 'iCloud'; remotePath = '/'; readWrite = $true; provider = 'iCloud'; iCloudService = 'drive'; extraArgs = @('--exclude', '*.tmp') }
          )
          replicas = @()
        }
      }
      try {
        Sync-CloudDriveCatalog -UserConfig $providerConfig -HomeDirectory $script:UserHome

        $path = Join-Path $script:WrapperDir 'mount-iCloud.ps1'
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty

        # The array literal is decoded through the parser, so a token that spans
        # the literal cannot slip past a naive string split.
        $arrayNode = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true) | Select-Object -First 1
        $tokens = @(
          $arrayNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            ForEach-Object { $_.SafeGetValue() }
        )

        # Anchors the assertion: without this, a failed decode would make every
        # absence check below pass against an empty list.
        $tokens | Should -Not -BeNullOrEmpty -Because 'this mount has extras, so the value must carry them'

        # The base five every catalog mount carries.
        $tokens | Should -Contain '--vfs-cache-mode'
        $tokens | Should -Contain 'full'
        $tokens | Should -Contain '--poll-interval'
        $tokens | Should -Contain 'NOTICE'

        # The per-mount flags and the extras.
        $tokens | Should -Contain '--iclouddrive-service'
        $tokens | Should -Contain 'drive'
        $tokens | Should -Contain '--exclude'

        # Everything passed as its own named parameter must not repeat in the array,
        # and a read-write mount must not carry the read-only flag.
        $tokens | Should -Not -Contain 'mount'
        $tokens | Should -Not -Contain 'iCloud:/'
        $tokens | Should -Not -Contain (Join-Path $script:UserHome 'clouds/iCloud')
        $tokens | Should -Not -Contain '--read-only'
      }
      finally {
        Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome
      }
    }
  }

  Context 'D60 - the remote value matches POSIX' {
    It 'passes the remote spec, not the bare remote name' {
      # POSIX passes remoteName:remotePath in the same position. Every current
      # registry entry uses remotePath "/", where the two forms are equivalent,
      # so a bare name is inert today, but a non-root remotePath would be
      # dropped and the remote root mounted instead.
      [regex]::Match($script:Wrapper['iCloud'], "-RemoteSpec '([^']*)'").Groups[1].Value |
        Should -Be 'iCloud:/'
    }
  }

  Context 'D57 - the resolved rclone directory reaches the wrapper' {
    It 'prepends the resolved rclone directory to PATH' {
      # The task runs `pwsh.exe -NoProfile`, so a bare `rclone` resolves only when
      # it happens to be on the user's registry PATH. The directory resolved at
      # apply time must be prepended at run time, and it must not be empty.
      $expected = [System.IO.Path]::GetDirectoryName((Get-Command rclone).Source)
      $emitted = [regex]::Match($script:Wrapper['iCloud'], "PATH = '([^;]*)")
      $emitted.Groups[1].Value | Should -Not -BeNullOrEmpty
      $emitted.Groups[1].Value | Should -Be $expected
    }
  }

  Context 'D56 - mount output is captured per instance' {
    It 'redirects the runner stdout and stderr to the instance log files' {
      # Without this the mount's output is discarded entirely, so a failure leaves no
      # evidence behind - not even the exit status.
      foreach ($id in 'iCloud', 'OneDrive') {
        $logDir = Join-Path (Get-NucleusLogDir) "cloud-drive-mount-$id"
        $script:Wrapper[$id] | Should -Match ([regex]::Escape("1>> '$(Join-Path $logDir 'stdout.log')'")) -Because "$id must capture stdout"
        $script:Wrapper[$id] | Should -Match ([regex]::Escape("2>> '$(Join-Path $logDir 'stderr.log')'")) -Because "$id must capture stderr"
      }
    }
  }

  Context 'D55 - an apostrophe in a value cannot break the wrapper' {
    It 'parses, and round-trips the values, when a path and an argument contain one' {
      # C:\Users\O'Brien is a real Windows profile shape. Values are emitted
      # inside single-quoted literals, so an unescaped apostrophe terminates the
      # literal and the scheduled task then runs a script that cannot be parsed,
      # failing silently in a hidden window, with no record and no log.
      $quotedHome = Join-Path $script:Root "O'Brien"
      $null = New-Item -ItemType Directory -Path $quotedHome -Force
      $quotedConfig = @{
        cloudDrives = @{
          mounts   = @(
            @{ id = 'iCloud'; enable = $true; localPath = "clouds/O'Brien"; remoteName = 'iCloud'; remotePath = '/'; readWrite = $true; extraArgs = @('--exclude', "O'Brien/secret") }
          )
          replicas = @()
        }
      }
      try {
        Sync-CloudDriveCatalog -UserConfig $quotedConfig -HomeDirectory $quotedHome

        $path = Join-Path $env:LOCALAPPDATA 'nucleus/cloud-drive/mount-iCloud.ps1'
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty -Because 'the generated wrapper must be parseable'

        # The values are read back through the parser, so this asserts the DECODED
        # value rather than the escaping syntax that happens to be in use.
        $decoded = @{}
        foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
          $elements = $command.CommandElements
          for ($i = 1; $i -lt $elements.Count; $i++) {
            if ($elements[$i].Extent.Text -eq '-MountPoint') {
              $decoded['MountPoint'] = $elements[$i + 1].SafeGetValue()
            }
            if ($elements[$i].Extent.Text -eq '-RcloneArgs') {
              $decoded['RcloneArgs'] = @(
                $elements[$i + 1].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                  ForEach-Object { $_.SafeGetValue() }
              )
            }
          }
        }

        $decoded['MountPoint'] | Should -Be (Join-Path $quotedHome "clouds/O'Brien")
        $decoded['RcloneArgs'] | Should -Contain "O'Brien/secret"
      }
      finally {
        Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome
      }
    }
  }
}

Describe 'Sync-CloudDriveCatalog mount filtering' {
  # WHY: 'enable' is optional and defaults to true (cloud-drives.nix mountSubmodule), so
  #   a mount that omits the key must still be provisioned.  The generator shares
  #   Test-NucleusMountEnabled with the declared-instance filter; these two cases pin both
  #   directions of that shared predicate on the generation side, so the two consumers
  #   cannot drift apart again.
  It 'generates a wrapper for a mount that omits enable, which defaults to true' {
    $config = @{
      cloudDrives = @{
        mounts   = @(
          @{ id = 'NoEnableKey'; localPath = 'clouds/NoEnableKey'; remoteName = 'iCloud'; remotePath = '/'; readWrite = $true }
        )
        replicas = @()
      }
    }
    Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome

    Test-Path -Path (Join-Path $env:LOCALAPPDATA 'nucleus/cloud-drive/mount-NoEnableKey.ps1') -PathType Leaf |
      Should -BeTrue -Because 'an omitted enable key means enabled'
  }

  It 'generates no wrapper for a mount that is explicitly disabled' {
    $config = @{
      cloudDrives = @{
        mounts   = @(
          @{ id = 'Disabled'; enable = $false; localPath = 'clouds/Disabled'; remoteName = 'iCloud'; remotePath = '/'; readWrite = $true }
        )
        replicas = @()
      }
    }
    Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome

    Test-Path -Path (Join-Path $env:LOCALAPPDATA 'nucleus/cloud-drive/mount-Disabled.ps1') -PathType Leaf |
      Should -BeFalse -Because 'an explicit false disables the mount'
  }
}
