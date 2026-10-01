<#
.SYNOPSIS
    Supervisor backend for Windows Task Scheduler.
.DESCRIPTION
  Implements the uniform Supervisor-* interface used by the service watchdog,
  driving the cloud mounts, CamillaDSP, and the watchdog itself, all of which
  are registered in Task Scheduler.

  Exactly one Supervisor-* adapter is loaded at a time. Both expose the same
  eight functions with the same -Target signature:

    Supervisor-Kind       -> 'schtask'
    Supervisor-Enabled    -Target -> [bool]
    Supervisor-Live       -Target -> [bool]
    Supervisor-Generation -Target -> [long]
    Supervisor-LastExit   -Target -> [int]
    Supervisor-Start      -Target -> no output
    Supervisor-Stop       -Target -> no output
    Supervisor-Repair     -Target -> no output

  -Target is the folder-qualified task id (e.g.
  '\NucleusCloudMount\NucleusCloudMount-iCloud'); the adapter splits it into
  the TaskPath and TaskName the ScheduledTasks cmdlets take.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Split-SupervisorTarget — split a folder-qualified task id into path and name.
function Split-SupervisorTarget {
    <#
    .SYNOPSIS
      Splits a folder-qualified scheduled-task id into its TaskPath and TaskName.
    .DESCRIPTION
      A task in the root folder has no separator, so the path falls back to '\'
      and the whole id is the name.
    .PARAMETER Target
      Folder-qualified task id.
    .OUTPUTS
      System.Collections.Hashtable with Path and Name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Target)

    $idx = $Target.LastIndexOf('\')
    if ($idx -lt 0) {
        return @{ Path = '\'; Name = $Target }
    }
    $path = $Target.Substring(0, $idx)
    if ([string]::IsNullOrEmpty($path)) { $path = '\' }
    @{ Path = $path; Name = $Target.Substring($idx + 1) }
}

# identifier of this adapter, used to load exactly one.
function Supervisor-Kind {
    <#
    .SYNOPSIS
      Returns this adapter's kind identifier.
    .OUTPUTS
      System.String
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'schtask'
}

# is the task registered and enabled?
function Supervisor-Enabled {
    <#
    .SYNOPSIS
      Reports whether the task exists and is allowed to run.
    .DESCRIPTION
      A task the user disabled is explicit intent, so it is reported as not
      enabled and the watchdog skips it instead of starting it.
    .PARAMETER Target
      Folder-qualified task id.
    .OUTPUTS
      System.Boolean
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Target)

    $parts = Split-SupervisorTarget -Target $Target
    # check-suppress:suppression_doc: an unregistered task is an expected state, not a failure
    $task = Get-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $false }
    $task.Settings.Enabled
}

# is the task currently running?
function Supervisor-Live {
    <#
    .SYNOPSIS
      Reports whether the task is running.
    .PARAMETER Target
      Folder-qualified task id.
    .OUTPUTS
      System.Boolean
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Target)

    $parts = Split-SupervisorTarget -Target $Target
    # check-suppress:suppression_doc: an unregistered task is an expected state, not a failure
    $task = Get-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction SilentlyContinue
    $null -ne $task -and $task.State -eq 'Running'
}

# token that changes whenever the task starts a run.
function Supervisor-Generation {
    <#
    .SYNOPSIS
      Reports a token that changes whenever the task starts a new run.
    .DESCRIPTION
      The scheduler exposes no restart counter, so the token is the task's last
      run time as unix seconds: it advances on every (re)start.  The watchdog
      compares successive tokens to spot restarts, which is why the value is
      only required to change, not to increase.
    .PARAMETER Target
      Folder-qualified task id.
    .OUTPUTS
      System.Int64
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$Target)

    $parts = Split-SupervisorTarget -Target $Target
    # check-suppress:suppression_doc: an unregistered task is an expected state, not a failure
    $info = Get-ScheduledTaskInfo -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction SilentlyContinue
    if ($null -eq $info) { return [long]0 }
    $lastRun = $info.LastRunTime
    if ($null -eq $lastRun -or $lastRun -eq [datetime]::MinValue) { return [long]0 }
    [long]([DateTimeOffset]::new($lastRun).ToUnixTimeSeconds())
}

# last result of the task.
function Supervisor-LastExit {
    <#
    .SYNOPSIS
      Reports the task's last result code.
    .PARAMETER Target
      Folder-qualified task id.
    .OUTPUTS
      System.Int32
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)

    $parts = Split-SupervisorTarget -Target $Target
    # check-suppress:suppression_doc: an unregistered task is an expected state, not a failure
    $info = Get-ScheduledTaskInfo -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction SilentlyContinue
    if ($null -eq $info) { return 0 }
    $info.LastTaskResult
}

# start the task.
function Supervisor-Start {
    <#
    .SYNOPSIS
      Starts the task.
    .PARAMETER Target
      Folder-qualified task id.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    $parts = Split-SupervisorTarget -Target $Target
    Start-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction Stop
}

# stop the task.
function Supervisor-Stop {
    <#
    .SYNOPSIS
      Stops the task.
    .PARAMETER Target
      Folder-qualified task id.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    $parts = Split-SupervisorTarget -Target $Target
    # check-suppress:suppression_doc: a stop racing an already-stopped task is not a convergence failure
    Stop-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction SilentlyContinue
}

# stop then start the task.
function Supervisor-Repair {
    <#
    .SYNOPSIS
      Restarts the task so it picks up a clean supervisor state.
    .PARAMETER Target
      Folder-qualified task id.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    Supervisor-Stop -Target $Target
    Start-Sleep -Seconds 1
    Supervisor-Start -Target $Target
}
