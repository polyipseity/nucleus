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

# HealthStateDir — returns the state directory path.
function Health-StateDir {
    [CmdletBinding()]
    param()
    $userData = Join-Path $env:LOCALAPPDATA 'nucleus'
    Join-Path (Join-Path $userData 'state') 'service-stats'
}

# Health-StateFile — returns the state file path for one instance.
function Health-StateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    Join-Path (Health-StateDir) "$Instance.json"
}

# Health-BootId — returns a boot identifier for freshness tracking.
function Health-BootId {
    [CmdletBinding()]
    param()
    $dir = Health-StateDir
    $file = Join-Path $dir '.boot-id'
    if (Test-Path $file) {
        return (Get-Content -Raw $file).Trim()
    }
    $val = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path $file -Value $val -NoNewline
    $val
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
        state      = 'stopped'
        'class'    = $null
        remedy     = $null
        attempts   = 0
        reported   = $false
        boot       = (Health-BootId)
        lastSuccess = 0
        restarts   = @()
        runs       = 0
        lastExit   = 0
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
    $json.reported = $false
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

# Health-IsBlocked — return true if the instance has a fresh blocked record.
function Health-IsBlocked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $state = Health-Get -Instance $Instance -Field 'state'
    if ($state -ne 'blocked') { return $false }
    $boot = Health-Get -Instance $Instance -Field 'boot'
    $boot -eq (Health-BootId)
}

# Health-IsReported — return true if the blocked record has been reported.
function Health-IsReported {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    (Health-Get -Instance $Instance -Field 'reported') -eq $true
}

# Health-MarkReported — mark the current blocked record as reported.
function Health-MarkReported {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    Health-Set -Instance $Instance -Field 'reported' -Value $true
}

# Health-Clear — remove class, remedy, and reported (re-arm).
function Health-Clear {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) { return }
    $tmp = "$file.tmp.$PID"
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $json.'class' = $null
    $json.remedy = $null
    $json.reported = $false
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
        Write-Host "service-health: recorded restart for $Instance ($Reason)"
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
    param([Parameter(Mandatory)][string]$Instance)
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) { return 0 }
    $json = Get-Content -Raw $file | ConvertFrom-Json
    $ls = if ($json.lastSuccess) { $json.lastSuccess } else { 0 }
    @($json.restarts | Where-Object { $_ -gt $ls }).Count
}

# Health-IsLooping — return true if the service is in a crash loop.
function Health-IsLooping {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $count = Health-RestartCount -Instance $Instance
    $consecutive = Health-ConsecutiveFailures -Instance $Instance
    ($count -ge 10) -or ($consecutive -ge 5)
}

# Health-Status — return status string.
function Health-Status {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $count = Health-RestartCount -Instance $Instance
    $consecutive = Health-ConsecutiveFailures -Instance $Instance
    if (($count -ge 10) -or ($consecutive -ge 5)) { 'LOOP' }
    elseif ($count -ge 5) { "${count}/hr" }
    else { 'OK' }
}

# Health-IncrementRuns — atomically increment the runs counter.
function Health-IncrementRuns {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Instance)
    $file = Health-StateFile -Instance $Instance
    if (-not (Test-Path $file)) { return }
    Health-Set -Instance $Instance -Field 'runs' -Value (
        (Health-Get -Instance $Instance -Field 'runs') + 1
    )
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

# Health-JsonKey — convert a service label to the record key.
function Health-JsonKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Label)
    $key = $Label -replace '^local\.cloud-mount-', '' `
                 -replace '^cloud-mount-', '' `
                 -replace '^NucleusCloudMount-', '' `
                 -replace '^n-', ''
    $key
}
