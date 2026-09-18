<#
.SYNOPSIS
  Pester tests for Get-NucleusServiceInstance.ps1 (prefix-match instance resolution).

.DESCRIPTION
  Covers instance id derivation from the registry fields, instance entry synthesis, and
  anchored live enumeration through a mocked Get-ScheduledTask.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/Get-NucleusServiceInstance.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  . (Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/Get-NucleusServiceInstance.ps1')

  # Get-ScheduledTask only exists on Windows and Pester can only Mock existing
  # commands, so the stub makes the cmdlet mockable on non-Windows CI hosts. The
  # default Mock reports an empty task list; tests override it per case.
  function Get-ScheduledTask { throw 'stub: Get-ScheduledTask' }
  Mock Get-ScheduledTask { return @() }

  # Real registry shape for the Windows cloud-drive entry: the folder lives in
  # taskPath and the task-name prefix in service.
  $Script:MountEntry = @{
    type        = 'schtask'
    prefixMatch = $true
    service     = 'NucleusCloudMount-'
    taskPath    = '\NucleusCloudMount'
    scope       = 'user'
  }

  # The user-registry fixture declares no mounts of its own, so it inherits the
  # three default mounts. Pester 6 does not share $Script: from a Describe-level
  # BeforeAll, so the fixture root is resolved here.
  $Script:FixtureRepoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '../../../fixtures/user-registry') -ErrorAction Stop).Path
}

Describe 'Get-NucleusInstanceIdPrefix' {
  It 'combines the task folder with the service prefix' {
    Get-NucleusInstanceIdPrefix -HostEntry $Script:MountEntry | Should -Be '\NucleusCloudMount\NucleusCloudMount-'
  }

  It 'uses the bare prefix when the entry declares no folder' {
    $entry = @{ type = 'schtask'; prefixMatch = $true; service = 'NucleusCloudMount-' }
    Get-NucleusInstanceIdPrefix -HostEntry $entry | Should -Be 'NucleusCloudMount-'
  }

  It 'normalizes a folder that already ends with a separator' {
    $entry = @{ type = 'schtask'; prefixMatch = $true; service = 'NucleusCloudMount-'; taskPath = '\NucleusCloudMount\' }
    Get-NucleusInstanceIdPrefix -HostEntry $entry | Should -Be '\NucleusCloudMount\NucleusCloudMount-'
  }

  It 'throws when the entry declares no service prefix' {
    { Get-NucleusInstanceIdPrefix -HostEntry @{ type = 'schtask'; prefixMatch = $true } } | Should -Throw '*no service prefix*'
  }
}

Describe 'Get-NucleusInstanceSuffix' {
  It 'strips the folder, the service prefix and the unit suffix' {
    Get-NucleusInstanceSuffix -HostEntry $Script:MountEntry -InstanceId '\NucleusCloudMount\NucleusCloudMount-iCloud' | Should -Be 'iCloud'
  }

  It 'handles a root-folder task id' {
    Get-NucleusInstanceSuffix -HostEntry $Script:MountEntry -InstanceId 'NucleusCloudMount-iCloud' | Should -Be 'iCloud'
  }

  It 'drops a systemd unit suffix' {
    $entry = @{ type = 'systemctl'; prefixMatch = $true; service = 'cloud-mount-'; scope = 'user' }
    Get-NucleusInstanceSuffix -HostEntry $entry -InstanceId 'cloud-mount-iCloud.service' | Should -Be 'iCloud'
  }

  It 'keeps the base name when the id lacks the declared prefix' {
    Get-NucleusInstanceSuffix -HostEntry $Script:MountEntry -InstanceId '\NucleusCloudMount\OtherTask' | Should -Be 'OtherTask'
  }
}

Describe 'New-NucleusInstanceHostEntry' {
  It 'points the instance entry at the concrete scheduled task' {
    $instance = New-NucleusInstanceHostEntry -HostEntry $Script:MountEntry -InstanceId '\NucleusCloudMount\NucleusCloudMount-work'
    $instance.type | Should -Be 'schtask'
    $instance.taskPath | Should -Be '\NucleusCloudMount\NucleusCloudMount-work'
    $instance.scope | Should -Be 'user'
  }

  It 'drops prefixMatch so the instance is not expanded again' {
    $instance = New-NucleusInstanceHostEntry -HostEntry $Script:MountEntry -InstanceId '\NucleusCloudMount\NucleusCloudMount-work'
    $instance.ContainsKey('prefixMatch') | Should -Be $false
  }

  It 'carries the concrete service name for non-schtask entries' {
    $entry = @{ type = 'launchctl'; prefixMatch = $true; service = 'local.cloud-mount.'; scope = 'user' }
    $instance = New-NucleusInstanceHostEntry -HostEntry $entry -InstanceId 'local.cloud-mount.iCloud'
    $instance.service | Should -Be 'local.cloud-mount.iCloud'
  }

  It 'leaves the registry entry untouched' {
    $entry = @{ type = 'schtask'; prefixMatch = $true; service = 'NucleusCloudMount-'; taskPath = '\NucleusCloudMount' }
    $null = New-NucleusInstanceHostEntry -HostEntry $entry -InstanceId '\NucleusCloudMount\NucleusCloudMount-work'
    $entry.taskPath | Should -Be '\NucleusCloudMount'
    $entry.prefixMatch | Should -Be $true
    $entry.ContainsKey('taskPath') | Should -Be $true
  }
}

Describe 'Get-NucleusPrefixInstanceList' {
  It 'returns only tasks whose full id matches the prefix' {
    Mock Get-ScheduledTask {
      return @(
        [PSCustomObject]@{ TaskName = 'NucleusCloudMount-work'; TaskPath = '\NucleusCloudMount\' }
        [PSCustomObject]@{ TaskName = 'NucleusCloudMountOther'; TaskPath = '\NucleusCloudMount\' }
        [PSCustomObject]@{ TaskName = 'OtherTask'; TaskPath = '\NucleusCloudMount\' }
        [PSCustomObject]@{ TaskName = 'NucleusCamillaDSP'; TaskPath = '\' }
      )
    }

    $instances = @(Get-NucleusPrefixInstanceList -HostEntry $Script:MountEntry)
    $instances.Count | Should -Be 1
    $instances[0] | Should -Be '\NucleusCloudMount\NucleusCloudMount-work'
  }

  It 'returns an empty list when no task matches' {
    Mock Get-ScheduledTask { return @() }

    $instances = @(Get-NucleusPrefixInstanceList -HostEntry $Script:MountEntry)
    $instances.Count | Should -Be 0
  }

  It 'returns every matching id sorted and unique' {
    Mock Get-ScheduledTask {
      return @(
        [PSCustomObject]@{ TaskName = 'NucleusCloudMount-b'; TaskPath = '\NucleusCloudMount\' }
        [PSCustomObject]@{ TaskName = 'NucleusCloudMount-a'; TaskPath = '\NucleusCloudMount\' }
        [PSCustomObject]@{ TaskName = 'NucleusCloudMount-a'; TaskPath = '\NucleusCloudMount\' }
      )
    }

    $instances = @(Get-NucleusPrefixInstanceList -HostEntry $Script:MountEntry)
    $instances.Count | Should -Be 2
    $instances[0] | Should -Be '\NucleusCloudMount\NucleusCloudMount-a'
    $instances[1] | Should -Be '\NucleusCloudMount\NucleusCloudMount-b'
  }

  It 'rejects a prefix-match entry of an unsupported type' {
    $entry = @{ type = 'native'; prefixMatch = $true; service = 'ollama' }
    { Get-NucleusPrefixInstanceList -HostEntry $entry } | Should -Throw '*unsupported type*'
  }

  It 'throws when the entry declares no type' {
    { Get-NucleusPrefixInstanceList -HostEntry @{ prefixMatch = $true; service = 'NucleusCloudMount-' } } | Should -Throw '*has no type*'
  }
}

Describe 'Get-NucleusConfiguredInstanceList' {
  It 'derives the expected task id from the declared mount' {
    $configured = @(Get-NucleusConfiguredInstanceList -HostEntry $Script:MountEntry -RepoRoot $Script:FixtureRepoRoot -Username 'test-user')
    $configured | Should -Contain '\NucleusCloudMount\NucleusCloudMount-iCloud'
  }

  It 'returns the declared mounts sorted' {
    $configured = @(Get-NucleusConfiguredInstanceList -HostEntry $Script:MountEntry -RepoRoot $Script:FixtureRepoRoot -Username 'test-user')
    $sorted = @($configured | Sort-Object)
    $configured.Count | Should -Be $sorted.Count
    for ($i = 0; $i -lt $configured.Count; $i++) {
      $configured[$i] | Should -Be $sorted[$i]
    }
  }

  It 'returns no id for a user without cloud-drive declarations' {
    $configured = @(Get-NucleusConfiguredInstanceList -HostEntry $Script:MountEntry -RepoRoot $Script:FixtureRepoRoot -Username 'no-such-user')
    $configured.Count | Should -Be 0
  }

  It 'reads every user when no username is given' {
    $configured = @(Get-NucleusConfiguredInstanceList -HostEntry $Script:MountEntry -RepoRoot $Script:FixtureRepoRoot)
    $configured | Should -Contain '\NucleusCloudMount\NucleusCloudMount-iCloud'
  }

  It 'throws when no repository root can be resolved' {
    $env:NUCLEUS_REPO_ROOT = $null
    { Get-NucleusConfiguredInstanceList -HostEntry $Script:MountEntry } | Should -Throw '*no repository root*'
  }

  It 'rejects a prefix-match entry of an unsupported type' {
    $entry = @{ type = 'native'; prefixMatch = $true; service = 'ollama' }
    { Get-NucleusConfiguredInstanceList -HostEntry $entry -RepoRoot $Script:FixtureRepoRoot } | Should -Throw '*unsupported type*'
  }
}
