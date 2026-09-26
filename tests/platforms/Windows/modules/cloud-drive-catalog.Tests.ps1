<#
.SYNOPSIS
  Pester tests for the Windows cloud-drive mount catalog generator.

.DESCRIPTION
  Sync-CloudDriveCatalog generates the per-mount wrapper the logon scheduled task
  runs.  That wrapper is the only place the mount's health-record key, mount point,
  read-only flag, and retry policy are decided, and every one of them is consumed in
  a DIFFERENT scope from the one that produced it: the wrapper runs later, in a fresh
  process, with no access to the $mount hashtable.

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
  . (Join-Path $modulesDir 'ServiceHealth.ps1')
  . (Join-Path $modulesDir 'user/Sync-CloudDriveCatalog.ps1')

  # ScheduledTasks is a Windows-only module; the generator calls these before and after
  # writing the wrapper.  Stubs keep the wrapper write on the real code path.
  # WHY the suppressions below: these are test doubles, not cmdlets.  Each shadows a real
  # ScheduledTasks cmdlet under its exact name — that name IS the shadowing mechanism, so it
  # cannot be renamed away — and each returns a [pscustomobject] without touching system
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
    param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable)
    [pscustomobject]@{}
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
    It 'writes the mount point the runner requires, not an empty value' {
      # The runner throws on an empty NUCLEUS_RCLONE_MOUNT_POINT before it initializes
      # a health record, so an empty value fails the mount silently and unrecorded.
      foreach ($id in 'iCloud', 'OneDrive') {
        $match = [regex]::Match($script:Wrapper[$id], "(?m)^\`$env:NUCLEUS_RCLONE_MOUNT_POINT = '(.*)'$")
        $match.Success | Should -BeTrue -Because "the wrapper for $id must set the mount point"
        $match.Groups[1].Value | Should -Not -BeNullOrEmpty -Because "$id must not carry an empty mount point"
        $match.Groups[1].Value | Should -Be (Join-Path $script:UserHome "clouds/$id") -Because 'the mount point is the per-mount local path'
      }
    }
  }

  Context 'D48 - read-only flag is resolved at generation time' {
    It 'marks a read-only mount read-only' {
      [regex]::Match($script:Wrapper['OneDrive'], "(?m)^\`$env:NUCLEUS_RCLONE_READ_ONLY = '(\w+)'$").Groups[1].Value | Should -Be 'true'
    }

    It 'marks a read-write mount writable' {
      [regex]::Match($script:Wrapper['iCloud'], "(?m)^\`$env:NUCLEUS_RCLONE_READ_ONLY = '(\w+)'$").Groups[1].Value | Should -Be 'false'
    }

    It 'writes the flag as a literal, not a deferred expression' {
      # The wrapper runs in a fresh process with no $mount hashtable.  A deferred
      # conditional would silently evaluate to writable for every mount.
      # The generated text is checked for the sub-expression itself: interpolating
      # $mount.<prop> inside the generator's string expands it there, so searching
      # for a variable reference would never match and the assertion could not fail.
      foreach ($id in 'iCloud', 'OneDrive') {
        $line = [regex]::Match($script:Wrapper[$id], "(?m)^\`$env:NUCLEUS_RCLONE_READ_ONLY = (.*)$").Groups[1].Value
        $line | Should -Not -Match '\$\(' -Because "$id must resolve the flag at generation time"
      }
    }
  }

  Context 'D45 - health-record key matches the watchdog' {
    It 'emits the folder-qualified instance id the watchdog resolves' {
      $entry = $script:Registry['cloud-drive'].hosts.Windows
      $watchdogId = Get-NucleusInstanceId -TaskFolder ([string]$entry.taskPath) -TaskName "$($entry.service)iCloud"
      $emitted = [regex]::Match($script:Wrapper['iCloud'], "(?m)^\`$env:NUCLEUS_CLOUD_MOUNT_INSTANCE = '(.*)'$").Groups[1].Value
      $emitted | Should -Be $watchdogId -Because 'a mismatched key writes a record the watchdog never reads'
    }

    It 'resolves to the same health record file the watchdog reads' {
      $entry = $script:Registry['cloud-drive'].hosts.Windows
      $watchdogId = Get-NucleusInstanceId -TaskFolder ([string]$entry.taskPath) -TaskName "$($entry.service)iCloud"
      $emitted = [regex]::Match($script:Wrapper['iCloud'], "(?m)^\`$env:NUCLEUS_CLOUD_MOUNT_INSTANCE = '(.*)'$").Groups[1].Value
      Get-HealthStateFile -Instance $emitted | Should -Be (Get-HealthStateFile -Instance $watchdogId)
    }
  }

  Context 'D46 - retry policy is derived from services.json' {
    It 'writes the lifecycle values the current registry defines' {
      $lifecycle = $script:Registry['cloud-drive'].lifecycle
      $emitted = @{}
      foreach ($key in 'NUCLEUS_MOUNT_ATTEMPTS', 'NUCLEUS_MOUNT_BACKOFF', 'NUCLEUS_MOUNT_ATTACH_SECONDS') {
        $emitted[$key] = [regex]::Match($script:Wrapper['iCloud'], "(?m)^\`$env:$key = '(.*)'$").Groups[1].Value
      }
      $emitted['NUCLEUS_MOUNT_ATTEMPTS'] | Should -Be ([string]$lifecycle.mountAttempts)
      $emitted['NUCLEUS_MOUNT_BACKOFF'] | Should -Be (($lifecycle.mountRetryBackoffSeconds | ForEach-Object { [string]$_ }) -join ',')
      $emitted['NUCLEUS_MOUNT_ATTACH_SECONDS'] | Should -Be ([string]$lifecycle.mountAttachTimeoutSeconds)
    }

    It 'follows the registry when the policy changes, so the values are derived not fixed' {
      # The parity check above cannot tell a derived value from a hardcoded one that
      # happens to match.  Changing the registry and requiring the output to change is
      # what proves the derivation; without it, fixed literals could return unnoticed.
      $mutatedRoot = Join-Path $script:Root 'mutated-repo'
      New-Item -ItemType Directory -Path (Join-Path $mutatedRoot 'src/modules') -Force > $null
      $mutated = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') | ConvertFrom-Json -AsHashtable
      $mutated['cloud-drive'].lifecycle.mountAttempts = 7
      $mutated['cloud-drive'].lifecycle.mountRetryBackoffSeconds = @(5, 9, 11)
      $mutated['cloud-drive'].lifecycle.mountAttachTimeoutSeconds = 99
      $mutated | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $mutatedRoot 'src/modules/services.json')

      $saved = $env:NUCLEUS_REPO_ROOT
      try {
        $env:NUCLEUS_REPO_ROOT = $mutatedRoot
        Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome

        $text = (Get-Content -Raw (Join-Path $script:WrapperDir 'mount-iCloud.ps1')) -replace "`r`n", "`n"
        [regex]::Match($text, "(?m)^\`$env:NUCLEUS_MOUNT_ATTEMPTS = '(.*)'$").Groups[1].Value | Should -Be '7'
        [regex]::Match($text, "(?m)^\`$env:NUCLEUS_MOUNT_BACKOFF = '(.*)'$").Groups[1].Value | Should -Be '5,9,11'
        [regex]::Match($text, "(?m)^\`$env:NUCLEUS_MOUNT_ATTACH_SECONDS = '(.*)'$").Groups[1].Value | Should -Be '99'
      }
      finally {
        # Restore the real registry and regenerate so the on-disk wrapper is canonical.
        $env:NUCLEUS_REPO_ROOT = $saved
        Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome
      }
    }
  }

  Context 'D59 - the wrapper carries only the per-mount extras' {
    It 'carries the per-mount extras and nothing the backend owns' {
      # The canonical fixture has no provider or extraArgs, so its arguments value is
      # legitimately empty and an absence check against it would pass for the wrong
      # reason.  This generates a mount that DOES have extras, so the value under test
      # is non-empty and both halves of the split are exercised.
      # The value spans lines (it is a list), so it is decoded through the parser: a
      # single-line regex silently yields an empty match for a multi-line value.
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

        $decoded = @{}
        foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
          $expr = if ($node.Right -is [System.Management.Automation.Language.CommandExpressionAst]) { $node.Right.Expression } else { $node.Right }
          if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $decoded[$node.Left.Extent.Text] = $expr.Value
          }
        }

        # Anchors the assertion: without this, a failed decode would make every
        # absence check below pass against an empty list.
        $value = $decoded['$env:NUCLEUS_RCLONE_ARGS']
        $value | Should -Not -BeNullOrEmpty -Because 'this mount has extras, so the value must carry them'
        $tokens = @($value -split '\s+' | Where-Object { $_ })

        # The extras the backend cannot know about.
        $tokens | Should -Contain '--iclouddrive-service'
        $tokens | Should -Contain 'drive'
        $tokens | Should -Contain '--exclude'

        # Everything the backend owns, which must not be repeated here.
        $tokens | Should -Not -Contain 'mount'
        $tokens | Should -Not -Contain 'iCloud:/'
        $tokens | Should -Not -Contain (Join-Path $script:UserHome 'clouds/iCloud')
        $tokens | Should -Not -Contain '--vfs-cache-mode'
        $tokens | Should -Not -Contain '--log-level'
        $tokens | Should -Not -Contain '--read-only'
      }
      finally {
        Sync-CloudDriveCatalog -UserConfig $config -HomeDirectory $script:UserHome
      }
    }
  }

  Context 'D60 - the remote value matches POSIX' {
    It 'emits the remote spec, not the bare remote name' {
      # POSIX sets NUCLEUS_RCLONE_REMOTE to remoteName:remotePath.  Every current
      # registry entry uses remotePath "/", where the two forms are equivalent, so a
      # bare name is inert today - but a non-root remotePath would be dropped and the
      # remote root mounted instead.
      [regex]::Match($script:Wrapper['iCloud'], "(?m)^\`$env:NUCLEUS_RCLONE_REMOTE = '(.*)'$").Groups[1].Value |
        Should -Be 'iCloud:/'
    }
  }

  Context 'D57 - the resolved rclone path is conveyed to the runner' {
    It 'sets NUCLEUS_RCLONE_BIN to the absolute path rclone resolves to' {
      # The task runs `pwsh.exe -NoProfile`, so a bare `rclone` resolves only when it
      # happens to be on the user's registry PATH.  The value must not be empty: an
      # empty string still activates the wrapper's line but leaves the runner on PATH.
      $emitted = [regex]::Match($script:Wrapper['iCloud'], "(?m)^\`$env:NUCLEUS_RCLONE_BIN = '(.*)'$").Groups[1].Value
      $emitted | Should -Not -BeNullOrEmpty
      $emitted | Should -Be (Get-Command rclone).Source
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
      # C:\Users\O'Brien is a real Windows profile shape.  Values are emitted inside
      # single-quoted literals, so an unescaped apostrophe terminates the literal and
      # the scheduled task then runs a script that cannot be parsed - failing silently
      # in a hidden window, with no record and no log.
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

        # The values are read back through the parser, so this asserts the DECODED value
        # rather than the escaping syntax that happens to be in use.  The right-hand side
        # of an assignment is a CommandExpressionAst wrapper, so the constant expression
        # inside it is what carries the value.
        $decoded = @{}
        foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
          $expr = if ($node.Right -is [System.Management.Automation.Language.CommandExpressionAst]) { $node.Right.Expression } else { $node.Right }
          $decoded[$node.Left.Extent.Text] = $expr.SafeGetValue()
        }

        $decoded['$env:NUCLEUS_RCLONE_MOUNT_POINT'] | Should -Be (Join-Path $quotedHome "clouds/O'Brien")
        $decoded['$env:NUCLEUS_RCLONE_ARGS'] | Should -Match ([regex]::Escape("O'Brien/secret"))
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
