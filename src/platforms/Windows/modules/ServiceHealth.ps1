<#
.SYNOPSIS
    Unified per-instance health record for nucleus services (Windows).
.DESCRIPTION
    Mirrors service-health.sh. Single JSON file per instance under
    <USER root>/state/service-stats/<instance>.json (or ProgramData for
    system-scope instances).

    The block setters assign to the record's fixed key set directly, which is
    safe only because every key they touch is one Initialize-HealthRecord
    writes. A key outside that set goes through Set-HealthField, which can add
    one. The evidence field stays absent from every record whose instance is not
    a mount runner, and the runner creates it the first time it keeps a capture
    file.

    ShouldProcess gating covers the New/Set/Remove verbs that PSScriptAnalyzer's
    PSUseShouldProcessForStateChangingFunctions inspects. The Initialize-, Add-
    and Clear- mutators write the same file ungated, so a -WhatIf pass reports
    the Set- calls only. No caller passes -WhatIf today.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Loop-detection thresholds, read only by Test-HealthLooping, which
# Get-HealthStatus also goes through, so the status a user sees can never
# disagree with the policy the watchdog enforces. Mirrors the _SVC_HEALTH_LOOP_*
# constants in src/scripts/lib/service-health.sh.
# WHY: -Force lets a re-dot-source refresh the values instead of throwing on an
# already-read-only variable.
Set-Variable -Name 'HealthLoopRestarts' -Value 10 -Option ReadOnly -Scope Script -Force
Set-Variable -Name 'HealthLoopConsecutive' -Value 5 -Option ReadOnly -Scope Script -Force
Set-Variable -Name 'HealthWarnRestarts' -Value 5 -Option ReadOnly -Scope Script -Force
Set-Variable -Name 'HealthBootUnknown' -Value 'unknown' -Option ReadOnly -Scope Script -Force

function Get-HealthStateDir {
    [CmdletBinding()]
    param()
    $userData = Join-Path $env:LOCALAPPDATA 'nucleus'
    Join-Path (Join-Path $userData 'state') 'service-stats'
}

# WHY: scheduled-task ids are folder-qualified (\Folder\Name), so separators and
# other reserved characters are replaced before an id becomes part of a file name.
# A raw id would nest the record under the folder and put it out of reach of
# Clear-HealthRecordAll's flat sweep, leaving a blocked instance un-re-armed at apply time.
# This is the ONE place the substitution lives.
function Get-HealthSafeInstanceName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Instance)
    $Instance -replace '[\\/:*?"<>|]', '_'
}

function Get-HealthStateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $safe = Get-HealthSafeInstanceName -Instance $Instance
    Join-Path (Get-HealthStateDir) "$safe.json"
}

# WHY the identity of the CURRENT boot is recomputed and never cached (it read a
#   sticky `<state dir>\.boot-id` file back forever): a record's boot is compared
#   against this value to decide whether a block is still in force, so the value
#   MUST change on reboot.
# WHY an unavailable boot time yields a sentinel instead of a fabricated value:
#   clearing a block is driven by the stored boot DIFFERING from this value, so
#   inventing one makes every block read as stale and silently voids the loop
#   protection. Failing open re-admits the restart storm the block prevents.
#   Mirrors svc_health_boot_id in service-health.sh.
function Get-HealthBootId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        # No -ErrorAction here: the module sets $ErrorActionPreference = 'Stop', so a
        # CIM failure already terminates and is caught below. The Pester stub for this
        # command takes no common parameters, so passing -ErrorAction would throw on it.
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        if ($null -eq $boot) { return $script:HealthBootUnknown }
        return $boot.ToString('o')
    } catch {
        return $script:HealthBootUnknown
    }
}

function Initialize-HealthRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Get-HealthStateFile -Instance $Instance
    if (Test-Path $file) { return }
    $dir = Split-Path -Parent $file
    New-Item -ItemType Directory -Path $dir -Force > $null
    @{
        state        = 'stopped'
        'class'      = $null
        remedy       = $null
        attempts     = 0
        reportedState = $null
        boot         = (Get-HealthBootId)
        lastSuccess  = 0
        restarts     = @()
        # WHY: null, not 0, is the "never observed" generation. A counter may
        # legitimately read 0 (systemd NRestarts), so zero cannot double as the
        # unknown sentinel without swallowing each service's first restart.
        generation   = $null
        lastExit     = 0
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $file -NoNewline
}

function Get-HealthField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Field
    )
    $file = Get-HealthStateFile -Instance $Instance
    if (-not (Test-Path $file)) { return $null }
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.$Field
}

function Set-HealthField {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Field,
        # WHY AllowNull alongside Mandatory: "this field has no value" is a value this
        #   setter has to accept, because the mount runner clears the evidence field by
        #   writing JSON null when a mount reaches running.
        [Parameter(Mandatory)][AllowNull()]$Value
    )
    if (-not $PSCmdlet.ShouldProcess("$Instance/$Field", 'write the service health field')) {
        return
    }
    $file = Get-HealthStateFile -Instance $Instance
    if (-not (Test-Path $file)) {
        Initialize-HealthRecord -Instance $Instance
    }
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    # WHY Add-Member rather than assignment: ConvertFrom-Json yields a PSCustomObject
    #   whose property set is exactly the keys the record carries, so `$json.$Field = $Value`
    #   throws "The property 'evidence' cannot be found on this object" for any field the
    #   record does not already have. -Force covers both the add and the update, and the
    #   POSIX side reaches the same shape through jq, which creates a missing key.
    $json | Add-Member -NotePropertyName $Field -NotePropertyValue $Value -Force
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

function Set-HealthBlocked {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][string]$Remedy
    )
    # Gate before Initialize-HealthRecord, which creates the record, so -WhatIf
    # cannot leave a new file behind.
    if (-not $PSCmdlet.ShouldProcess($Instance, 'block the service health record')) {
        return
    }
    Initialize-HealthRecord -Instance $Instance
    $file = Get-HealthStateFile -Instance $Instance
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.state = 'blocked'
    $json.'class' = $Class
    $json.remedy = $Remedy
    $json.boot = (Get-HealthBootId)
    $json.reportedState = $null
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

function Set-HealthRunning {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Instance)
    if (-not $PSCmdlet.ShouldProcess($Instance, 'mark the service health record running')) {
        return
    }
    Initialize-HealthRecord -Instance $Instance
    $file = Get-HealthStateFile -Instance $Instance
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.state = 'running'
    $json.'class' = $null
    $json.remedy = $null
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

# Fresh means the record was written during the CURRENT boot, so a record from a
# previous boot stops gating the service, which is how a reboot clears a block
# (the other way being the apply-time re-arm).
# WHY the unknown/absent guards: when the OS cannot report a boot time, or the
# record carries no boot stamp, a mismatch is NOT evidence of a reboot, so the
# block is KEPT (fail closed). See Get-HealthBootId.
function Test-HealthBlocked {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Instance)
    $state = Get-HealthField -Instance $Instance -Field 'state'
    if ($state -ne 'blocked') { return $false }
    $boot = Get-HealthField -Instance $Instance -Field 'boot'
    $current = Get-HealthBootId
    if ([string]::IsNullOrEmpty($current) -or $current -eq $script:HealthBootUnknown) { return $true }
    if ([string]::IsNullOrEmpty($boot) -or $boot -eq $script:HealthBootUnknown) { return $true }
    return ($boot -eq $current)
}

function Test-HealthReported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Expected
    )
    (Get-HealthField -Instance $Instance -Field 'reportedState') -eq $Expected
}

function Set-HealthReported {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$State
    )
    if (-not $PSCmdlet.ShouldProcess($Instance, 'mark the reported state')) {
        return
    }
    Set-HealthField -Instance $Instance -Field 'reportedState' -Value $State
}

# WHY: Test-HealthLooping reads .restarts, so a clear that kept the history would
# be re-blocked by the watchdog's Rule 3 on the very next tick. Dropping
# .restarts is what makes this a re-arm rather than a status reset. The evidence
# field is left alone because it still names a capture file the runner kept.
# Mirrors svc_health_clear in src/scripts/lib/service-health.sh.
function Clear-HealthRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Get-HealthStateFile -Instance $Instance
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

function Clear-HealthRecordAll {
    [CmdletBinding()]
    param()
    $dir = Get-HealthStateDir
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem -Path $dir -Filter '*.json' | ForEach-Object {
        Clear-HealthRecord -Instance $_.BaseName
    }
}

function Add-HealthRestart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$Reason = ''
    )
    Initialize-HealthRecord -Instance $Instance
    $file = Get-HealthStateFile -Instance $Instance
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $cutoff = $now - 3600
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $filtered = @($json.restarts | Where-Object { $_ -gt $cutoff })
    $json.restarts = @($filtered) + @($now)
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
    if ($Reason) {
        # WHY: Write-Output, not Write-Host. The only caller is the service-watchdog,
        #   which runs as a captured daemon (services.json logging.capture: all), and
        #   Write-Host goes to the information stream the capture does not collect.
        Write-Output "service-health: recorded restart for $Instance ($Reason)"
    }
}

function Set-HealthSuccess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Instance)
    # Gate before Initialize-HealthRecord, which creates the record, so -WhatIf
    # cannot leave a new file behind.
    if (-not $PSCmdlet.ShouldProcess($Instance, 'stamp the last-success time')) {
        return
    }
    Initialize-HealthRecord -Instance $Instance
    Set-HealthField -Instance $Instance -Field 'lastSuccess' -Value (
        [DateTimeOffset]::Now.ToUnixTimeSeconds()
    )
}

function Get-HealthRestartCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Get-HealthStateFile -Instance $Instance
    if (-not (Test-Path $file)) { return 0 }
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $cutoff = $now - 3600
    $json = Get-Content -Raw $file | ConvertFrom-Json
    @($json.restarts | Where-Object { $_ -gt $cutoff }).Count
}

function Get-HealthConsecutiveFailureCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Get-HealthStateFile -Instance $Instance
    if (-not (Test-Path $file)) { return 0 }
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $ls = if ($json.lastSuccess) { $json.lastSuccess } else { 0 }
    @($json.restarts | Where-Object { $_ -gt $ls }).Count
}

# WHY: the only place the loop thresholds are compared, so Get-HealthStatus
# delegates here instead of re-implementing the comparison.
function Test-HealthLooping {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Instance)
    $count = Get-HealthRestartCount -Instance $Instance
    $consecutive = Get-HealthConsecutiveFailureCount -Instance $Instance
    ($count -ge $script:HealthLoopRestarts) -or ($consecutive -ge $script:HealthLoopConsecutive)
}

function Get-HealthStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Instance)
    if (Test-HealthLooping -Instance $Instance) {
        'LOOP'
    } else {
        $count = Get-HealthRestartCount -Instance $Instance
        if ($count -ge $script:HealthWarnRestarts) { "${count}/hr" } else { 'OK' }
    }
}

function Set-HealthLastExitCode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][int]$ExitCode
    )
    if (-not $PSCmdlet.ShouldProcess($Instance, 'record the last exit code')) {
        return
    }
    Set-HealthField -Instance $Instance -Field 'lastExit' -Value $ExitCode
}
