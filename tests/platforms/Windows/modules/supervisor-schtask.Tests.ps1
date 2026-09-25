<#
.SYNOPSIS
  Pester tests for the Task Scheduler supervisor adapter.

.DESCRIPTION
  The watchdog loads exactly one Supervisor-* adapter per service kind, so the
  adapter must expose the uniform interface and split a folder-qualified task id
  into the TaskPath and TaskName the ScheduledTasks cmdlets take.  Those cmdlets
  are stubbed on hosts where they do not exist so the suite runs anywhere.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/supervisor-schtask.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $modulesDir = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules'
  . (Join-Path $modulesDir 'Supervisor-Schtask.ps1')

  $stubs = @{
    'Get-ScheduledTask'     = 'param([string]$TaskPath, [string]$TaskName)'
    'Get-ScheduledTaskInfo' = 'param([string]$TaskPath, [string]$TaskName)'
    'Start-ScheduledTask'   = 'param([string]$TaskPath, [string]$TaskName)'
    'Stop-ScheduledTask'    = 'param([string]$TaskPath, [string]$TaskName)'
  }
  foreach ($name in $stubs.Keys) {
    if (-not (Get-Command -Name $name -ErrorAction Ignore)) {
      Set-Item -Path "Function:$name" -Value ([scriptblock]::Create("$($stubs[$name])`nthrow 'stub: override with Mock'"))
    }
  }
}

Describe 'Supervisor-Kind' {
  It 'identifies the adapter' {
    (Supervisor-Kind) | Should -Be 'schtask'
  }
}

Describe 'Split-SupervisorTarget' {
  It 'splits a task registered in a folder' {
    $parts = Split-SupervisorTarget -Target '\NucleusCloudMount\NucleusCloudMount-iCloud'

    $parts.Path | Should -Be '\NucleusCloudMount'
    $parts.Name | Should -Be 'NucleusCloudMount-iCloud'
  }

  It 'puts a task registered in the root folder in the root path' {
    $parts = Split-SupervisorTarget -Target '\NucleusCamillaDSP'

    $parts.Path | Should -Be '\'
    $parts.Name | Should -Be 'NucleusCamillaDSP'
  }

  It 'treats a bare name as a root-folder task' {
    $parts = Split-SupervisorTarget -Target 'nucleus-watchdog'

    $parts.Path | Should -Be '\'
    $parts.Name | Should -Be 'nucleus-watchdog'
  }
}

Describe 'Supervisor-Enabled' {
  It 'is false when the task is not registered' {
    Mock Get-ScheduledTask { return $null }

    (Supervisor-Enabled -Target '\NucleusCloudMount\mount-iCloud') | Should -BeFalse
  }

  It 'is false when the user disabled the task' {
    Mock Get-ScheduledTask {
      return [PSCustomObject]@{ TaskName = $TaskName; TaskPath = $TaskPath; State = 'Ready'; Settings = [PSCustomObject]@{ Enabled = $false } }
    }

    (Supervisor-Enabled -Target '\NucleusCloudMount\mount-iCloud') | Should -BeFalse
  }

  It 'is true for an enabled task' {
    Mock Get-ScheduledTask {
      return [PSCustomObject]@{ TaskName = $TaskName; TaskPath = $TaskPath; State = 'Ready'; Settings = [PSCustomObject]@{ Enabled = $true } }
    }

    (Supervisor-Enabled -Target '\NucleusCloudMount\mount-iCloud') | Should -BeTrue
  }

  It 'queries the task by its split path and name' {
    $script:Queried = @()
    Mock Get-ScheduledTask {
      $script:Queried += "$TaskPath|$TaskName"
      return [PSCustomObject]@{ TaskName = $TaskName; TaskPath = $TaskPath; State = 'Ready'; Settings = [PSCustomObject]@{ Enabled = $true } }
    }

    Supervisor-Enabled -Target '\NucleusCloudMount\mount-iCloud' > $null

    $script:Queried | Should -Be @('\NucleusCloudMount|mount-iCloud')
  }
}

Describe 'Supervisor-Live' {
  It 'is true only while the task runs' {
    Mock Get-ScheduledTask {
      return [PSCustomObject]@{ TaskName = $TaskName; TaskPath = $TaskPath; State = 'Running'; Settings = [PSCustomObject]@{ Enabled = $true } }
    }
    (Supervisor-Live -Target '\NucleusCloudMount\mount-iCloud') | Should -BeTrue

    Mock Get-ScheduledTask {
      return [PSCustomObject]@{ TaskName = $TaskName; TaskPath = $TaskPath; State = 'Ready'; Settings = [PSCustomObject]@{ Enabled = $true } }
    }
    (Supervisor-Live -Target '\NucleusCloudMount\mount-iCloud') | Should -BeFalse
  }
}

Describe 'Supervisor-Generation and Supervisor-LastExit' {
  It 'reports the last run time as unix seconds for the split target' {
    Mock Get-ScheduledTaskInfo {
      return [PSCustomObject]@{ LastRunTime = [datetime]'2026-01-02T03:04:05Z'; LastTaskResult = 78 }
    }

    $expected = [DateTimeOffset]::new([datetime]'2026-01-02T03:04:05Z').ToUnixTimeSeconds()
    (Supervisor-Generation -Target '\NucleusCloudMount\mount-iCloud') | Should -Be $expected
    (Supervisor-LastExit -Target '\NucleusCloudMount\mount-iCloud') | Should -Be 78
  }

  It 'reports zero when the task has no info' {
    Mock Get-ScheduledTaskInfo { return $null }

    (Supervisor-Generation -Target '\NucleusCloudMount\mount-iCloud') | Should -Be 0
    (Supervisor-LastExit -Target '\NucleusCloudMount\mount-iCloud') | Should -Be 0
  }

  It 'reports zero when the task has never run' {
    Mock Get-ScheduledTaskInfo {
      return [PSCustomObject]@{ LastRunTime = [datetime]::MinValue; LastTaskResult = 0 }
    }

    (Supervisor-Generation -Target '\NucleusCloudMount\mount-iCloud') | Should -Be 0
  }
}

Describe 'Supervisor-Start' {
  It 'starts the task by its split path and name' {
    $script:Started = @()
    Mock Start-ScheduledTask { $script:Started += "$TaskPath|$TaskName" }

    Supervisor-Start -Target '\NucleusCloudMount\mount-iCloud'

    $script:Started | Should -Be @('\NucleusCloudMount|mount-iCloud')
  }
}

Describe 'Supervisor-Stop' {
  It 'stops the task by its split path and name' {
    $script:Stopped = @()
    Mock Stop-ScheduledTask { $script:Stopped += "$TaskPath|$TaskName" }

    Supervisor-Stop -Target '\NucleusCloudMount\mount-iCloud'

    $script:Stopped | Should -Be @('\NucleusCloudMount|mount-iCloud')
  }
}

Describe 'Supervisor-Repair' {
  It 'stops and then starts the task' {
    $script:Calls = @()
    Mock Stop-ScheduledTask { $script:Calls += "stop:$TaskName" }
    Mock Start-ScheduledTask { $script:Calls += "start:$TaskName" }
    Mock Start-Sleep { }

    Supervisor-Repair -Target '\NucleusCloudMount\mount-iCloud'

    $script:Calls | Should -Be @('stop:mount-iCloud', 'start:mount-iCloud')
  }
}
