<#
.SYNOPSIS
    Unified per-instance health record for nucleus services (Windows).
.DESCRIPTION
    Mirrors service-health.sh. Single JSON file per instance under
    <USER root>/state/service-stats/<instance>.json (or ProgramData for
    system-scope instances).

    Record schema matches the POSIX version exactly.
.PARAMETER Instance
    Service instance key (e.g. "iCloud", "GoogleDrive").
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Loop-detection thresholds, defined once and read only by Health-IsLooping.
# Health-Status reports through that same predicate, so the status a user sees
# can never disagree with the policy the watchdog enforces.  Mirrors the
# _SVC_HEALTH_LOOP_* constants in src/scripts/lib/service-health.sh.
# WHY: -Force lets a re-dot-source refresh the values instead of throwing on an
# already-read-only variable.
Set-Variable -Name 'HealthLoopRestarts' -Value 10 -Option ReadOnly -Scope Script -Force
Set-Variable -Name 'HealthLoopConsecutive' -Value 5 -Option ReadOnly -Scope Script -Force
Set-Variable -Name 'HealthWarnRestarts' -Value 5 -Option ReadOnly -Scope Script -Force
# Sentinel for "the OS could not report a boot time" — see Health-BootId.
Set-Variable -Name 'HealthBootUnknown' -Value 'unknown' -Option ReadOnly -Scope Script -Force

# HealthStateDir — returns the state directory path.
function Health-StateDir {
    [CmdletBinding()]
    param()
    $userData = Join-Path $env:LOCALAPPDATA 'nucleus'
    Join-Path (Join-Path $userData 'state') 'service-stats'
}

# Get-HealthSafeInstanceName — map a service instance id to a path-safe token.
# WHY: scheduled-task ids are folder-qualified (\Folder\Name), so separators and
# other reserved characters are replaced before an id becomes part of a file name.
# A raw id would nest the record under the folder and put it out of reach of
# Health-ClearAll's flat sweep, leaving a blocked instance un-re-armed at apply time.
# This is the ONE place the substitution lives; every caller that builds a path from
# an instance id reuses it rather than repeating the pattern.
# WHY: named with an approved verb instead of the file's Health-<Noun> style so this
# new function adds no PSUseApprovedVerbs finding to an already-red file.
function Get-HealthSafeInstanceName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Instance)
    $Instance -replace '[\\/:*?"<>|]', '_'
}

# Health-StateFile — returns the state file path for one instance.
function Health-StateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $safe = Get-HealthSafeInstanceName -Instance $Instance
    Join-Path (Health-StateDir) "$safe.json"
}

# Health-BootId — the identity of the CURRENT boot, asked of the OS on every
# call.  Mirrors svc_health_boot_id in service-health.sh.
#
# WHY this is recomputed and never cached (it previously read a sticky
# `<state dir>\.boot-id` file back forever): a record's boot is compared against
# this value to decide whether a block is still in force, so the value MUST
# change when the OS reboots.  A cached copy cannot, which left the documented
# "a reboot clears a block" contract unreachable.
#
# WHY an unavailable boot time yields a sentinel instead of a fabricated value:
# clearing a block is driven by the stored boot DIFFERING from this value, so
# inventing one when the OS cannot be asked would make every block read as stale
# and silently void the loop protection.  The sentinel means "not evidence of a
# reboot", and Health-IsBlocked keeps the block.  Failing closed costs a blocked
# instance nothing the apply-time re-arm (Health-ClearAll via apply) cannot fix;
# failing open re-admits the restart storm the block exists to prevent.
function Health-BootId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        # No -ErrorAction here: the module sets $ErrorActionPreference = 'Stop' at
        # the top, so a CIM failure already terminates and is caught below.  The
        # Pester stub for this command is a simple function with no common
        # parameters, so passing -ErrorAction would throw on the stub itself.
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        if ($null -eq $boot) { return $script:HealthBootUnknown }
        return $boot.ToString('o')
    } catch {
        # The OS could not report a boot time.  Fail closed, as documented above.
        return $script:HealthBootUnknown
    }
}

# Health-Init — ensure the state file exists with defaults.
function Health-Init {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Health-StateFile -Instance $Instance
    if (Test-Path $file) { return }
    $dir = Split-Path -Parent $file
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    @{
        state        = 'stopped'
        'class'      = $null
        remedy       = $null
        attempts     = 0
        reportedState = $null
        boot         = (Health-BootId)
        lastSuccess  = 0
        restarts     = @()
        # WHY: null, not 0, is the "never observed" generation.  A counter may
        # legitimately read 0 (systemd NRestarts), so zero cannot double as the
        # unknown sentinel without swallowing each service's first restart.
        generation   = $null
        lastExit     = 0
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $file -NoNewline
}

# Health-Get — read a single field from the record.
function Health-Get {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Field
    )
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) { return $null }
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.$Field
}

# Health-Set — write a field to the record. Atomic via tmp+mv.
function Health-Set {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)]$Value
    )
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) {
        Health-Init -Instance $Instance
    }
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.$Field = $Value
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

# Health-SetBlocked — set state to blocked with class and remedy.
function Health-SetBlocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][string]$Remedy
    )
    Health-Init -Instance $Instance
    $file = Health-StateFile -Instance $Instance
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.state = 'blocked'
    $json.'class' = $Class
    $json.remedy = $Remedy
    $json.boot = (Health-BootId)
    $json.reportedState = $null
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

# Health-SetRunning — clear the blocker fields and mark the instance running.
function Health-SetRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    Health-Init -Instance $Instance
    $file = Health-StateFile -Instance $Instance
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.state = 'running'
    $json.'class' = $null
    $json.remedy = $null
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

# Health-IsBlocked — return true if the instance has a fresh blocked record.
# Fresh means the record was written during the CURRENT boot, so a record from a
# previous boot stops gating the service — that is how a reboot clears a block
# (the other way being the apply-time re-arm).
# WHY the unknown/absent guards: when the OS cannot report a boot time, or the
# record carries no boot stamp at all, a mismatch is NOT evidence of a reboot,
# so the block is KEPT (fail closed).  See Health-BootId.
function Health-IsBlocked {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Instance)
    $state = Health-Get -Instance $Instance -Field 'state'
    if ($state -ne 'blocked') { return $false }
    $boot = Health-Get -Instance $Instance -Field 'boot'
    $current = Health-BootId
    if ([string]::IsNullOrEmpty($current) -or $current -eq $script:HealthBootUnknown) { return $true }
    if ([string]::IsNullOrEmpty($boot) -or $boot -eq $script:HealthBootUnknown) { return $true }
    return ($boot -eq $current)
}

# Health-IsReported — return true if the current state has been reported.
# Args: $Instance, $Expected reportedState string.
function Health-IsReported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Expected
    )
    (Health-Get -Instance $Instance -Field 'reportedState') -eq $Expected
}

# Health-MarkReported — mark the current state as reported.
# Args: $Instance, $State reportedState string.
function Health-MarkReported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$State
    )
    Health-Set -Instance $Instance -Field 'reportedState' -Value $State
}

# Health-Clear — re-arm the instance: drop class, remedy, and reportedState,
# return state to 'stopped', and drop the restart history, so that neither a
# blocked state NOR a loop history survives the re-arm.  Rule 2 never
# auto-revives, so a record left at state 'blocked' would stay blocked until reboot
# even though apply had already re-armed it.
# WHY: Health-IsLooping reads .restarts, so a clear that kept the history would be
#   re-blocked by the watchdog's Rule 3 on the very next tick and would stay
#   blocked until the old timestamps aged out.  Dropping .restarts is what makes
#   this a re-arm rather than a status reset.  Mirrors svc_health_clear in
#   src/scripts/lib/service-health.sh.
function Health-Clear {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) { return }
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.state = 'stopped'
    $json.'class' = $null
    $json.remedy = $null
    $json.reportedState = $null
    $json.restarts = @()
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

# Health-ClearAll — clear all instances (apply-time re-arm).
function Health-ClearAll {
    [CmdletBinding()]
    param()
    $dir = Health-StateDir
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem -Path $dir -Filter '*.json' | ForEach-Object {
        Health-Clear -Instance $_.BaseName
    }
}

# Health-RecordRestart — append a restart timestamp, prune >1 hour.
function Health-RecordRestart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$Reason = ''
    )
    Health-Init -Instance $Instance
    $file = Health-StateFile -Instance $Instance
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $cutoff = $now - 3600
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $filtered = @($json.restarts | Where-Object { $_ -gt $cutoff })
    $json.restarts = @($filtered) + @($now)
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
    if ($Reason) {
        # WHY: Write-Output, not Write-Host — the only caller is the service-watchdog,
        #   which runs as a captured daemon (services.json logging.capture: all), so its
        #   stdout lands in a log file.  Write-Host goes to the information stream, which
        #   the capture does not collect, and the verbose/information streams are hidden
        #   under the default preference variables, so the restart record would be lost.
        Write-Output "service-health: recorded restart for $Instance ($Reason)"
    }
}

# Health-RecordSuccess — update lastSuccess to now.
function Health-RecordSuccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    Health-Init -Instance $Instance
    Health-Set -Instance $Instance -Field 'lastSuccess' -Value (
        [DateTimeOffset]::Now.ToUnixTimeSeconds()
    )
}

# Health-RestartCount — count restarts in the last hour.
function Health-RestartCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) { return 0 }
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $cutoff = $now - 3600
    $json = Get-Content -Raw $file | ConvertFrom-Json
    @($json.restarts | Where-Object { $_ -gt $cutoff }).Count
}

# Health-ConsecutiveFailures — count restarts newer than lastSuccess.
function Health-ConsecutiveFailures {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) { return 0 }
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $ls = if ($json.lastSuccess) { $json.lastSuccess } else { 0 }
    @($json.restarts | Where-Object { $_ -gt $ls }).Count
}

# Health-IsLooping — return true if the service is in a crash loop.
# WHY: the only place the loop thresholds are compared; Health-Status delegates
# here rather than re-implementing the comparison.
function Health-IsLooping {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Instance)
    $count = Health-RestartCount -Instance $Instance
    $consecutive = Health-ConsecutiveFailures -Instance $Instance
    ($count -ge $script:HealthLoopRestarts) -or ($consecutive -ge $script:HealthLoopConsecutive)
}

# Health-Status — return status string.
function Health-Status {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Instance)
    if (Health-IsLooping -Instance $Instance) {
        'LOOP'
    } else {
        $count = Health-RestartCount -Instance $Instance
        if ($count -ge $script:HealthWarnRestarts) { "${count}/hr" } else { 'OK' }
    }
}

# Health-SetLastExit — update lastExit.
function Health-SetLastExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][int]$ExitCode
    )
    Health-Set -Instance $Instance -Field 'lastExit' -Value $ExitCode
}
