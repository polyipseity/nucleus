<#
.SYNOPSIS
    Supervisor backend for Windows Task Scheduler.
.DESCRIPTION
    Implements Supervisor-* functions for the service-watchdog core runner.
    Handles scheduled tasks (cloud mounts, service-watchdog, etc).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Supervisor-Enabled — is the scheduled task registered?
function Supervisor-Enabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath
    )
    $null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue)
}

# Supervisor-Live — is the task currently running?
function Supervisor-Live {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskName, [string]$TaskPath = '\')
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    $task -and $task.State -eq 'Running'
}

# Supervisor-Counter — return the number of times the task has run.
function Supervisor-Counter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$TaskPath = '\'
    )
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($info) { $info.NumberOfMissedRuns } else { 0 }
}

# Supervisor-LastExit — return the last task result code.
function Supervisor-LastExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$TaskPath = '\'
    )
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($info) { $info.LastTaskResult } else { 0 }
}

# Supervisor-Start — start a scheduled task.
function Supervisor-Start {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$TaskPath = '\'
    )
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
}

# Supervisor-Stop — stop a scheduled task.
function Supervisor-Stop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$TaskPath = '\'
    )
    Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
}

# Supervisor-Repair — re-register and start a task.
function Supervisor-Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$TaskPath = '\'
    )
    # For scheduled tasks, repair is stop + start.
    Supervisor-Stop -TaskName $TaskName -TaskPath $TaskPath
    Start-Sleep -Seconds 1
    Supervisor-Start -TaskName $TaskName -TaskPath $TaskPath
}

# Supervisor-Kind — return the supervisor kind identifier.
function Supervisor-Kind {
    'schtask'
}
