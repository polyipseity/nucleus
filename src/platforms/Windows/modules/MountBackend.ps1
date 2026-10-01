<#
.SYNOPSIS
    Mount backend for Windows: WinFsp.
.DESCRIPTION
    WinFsp specifics stay in this file; the core runner never names them.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Script:_BackendCapture = $null
$Script:_BackendRclonePid = $null

function Mount-Backend-Class {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$CaptureFile)

    if (-not (Test-Path $CaptureFile)) { return 'mount-failed' }
    # check-suppress:suppression_doc: an unreadable capture file yields $null, which the empty-content branch below turns into the same 'mount-failed' verdict
    $content = Get-Content -Raw $CaptureFile -ErrorAction SilentlyContinue
    if (-not $content) { return 'mount-failed' }

    if ($content -match 'Unauthorized|Invalid credentials|unauthorized_request|auth.*failed|401') {
        return 'auth'
    }
    if ($content -match 'not found|does not exist|Unknown remote|Couldn.*list files|directory not found') {
        return 'remote-not-found'
    }
    if ($content -match 'permission denied|operation not permitted|access denied|No such file or directory') {
        return 'path-permission'
    }
    if ($content -match 'connection refused|connection reset|timeout|resource temporarily unavailable|device or resource busy') {
        return 'io-transient'
    }
    if ($content -match 'WinFsp.*not found|winfsp.*failed|FUSE.*not available') {
        return 'provider-refusal'
    }
    return 'mount-failed'
}

function Mount-Backend-Remedy {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Class)

    switch ($Class) {
        'provider-refusal' { 'restart WinFsp Launcher service and re-install WinFsp' }
        'io-transient'     { 'retry in progress' }
        'auth'             { 'verify remote credentials' }
        'remote-not-found' { 'check remote name and configuration' }
        'path-permission'  { 'check mount point permissions' }
        default            { 'check remote configuration and credentials' }
    }
}

function Mount-Backend-IsTransient {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Class)
    $Class -in @('provider-refusal', 'io-transient')
}

function Mount-Backend-Prepare {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)

    # check-suppress:suppression_doc: a missing command throws; the -not test on the next line is the absence probe
    $winfsp = Get-Command 'winfsp-x64.dll' -ErrorAction SilentlyContinue
    if (-not $winfsp) {
        $regPath = 'HKLM:\SOFTWARE\WOW6432Node\WinFsp'
        if (-not (Test-Path $regPath)) {
            $regPath = 'HKLM:\SOFTWARE\WinFsp'
        }
        if (-not (Test-Path $regPath)) {
            . "$PSScriptRoot\ServiceHealth.ps1"
            Set-HealthBlocked -Instance $Instance -Class 'provider-refusal' -Remedy 'install WinFsp via winget install WinFsp.WinFsp'
            return 20
        }
    }

    # check-suppress:suppression_doc: an absent service leaves $svc null, so the -and guard below skips the start and not-running is the answer
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        # WHY: rclone-mount.ps1 has no try/catch and handles only rc 20, so an escaping
        #   exception kills the mount loop before any health record exists.
        try {
            Start-Service -Name 'WinFsp.Launcher'
        } catch {
            . "$PSScriptRoot\ServiceHealth.ps1"
            Set-HealthBlocked -Instance $Instance -Class 'provider-refusal' -Remedy 'start WinFsp.Launcher from an elevated session; the mount task runs unelevated'
            return 20
        }
    }

    return 0
}

function Mount-Backend-ArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][bool]$ReadOnly,
        [string]$ExtraArgs = ''
    )

    # WHY: $rcloneFlags, not $args, which is the automatic variable and has
    #   undesired side effects when reassigned.
    $rcloneFlags = @($Remote, $MountPoint,
        '--vfs-cache-mode', 'full',
        '--vfs-cache-max-age', '1h',
        '--dir-cache-time', '5m',
        '--poll-interval', '1m',
        '--log-level', 'NOTICE')

    if ($ReadOnly) { $rcloneFlags += '--read-only' }

    if ($ExtraArgs) {
        $rcloneFlags += ($ExtraArgs -split '\s+' | Where-Object { $_ })
    }

    $rcloneFlags
}

function Mount-Backend-Mount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RcloneBin,
        # WHY: $MountArgs, not $Args, which is the automatic variable.
        [Parameter(Mandatory)][string[]]$MountArgs,
        [Parameter(Mandatory)][string]$CaptureFile
    )

    $Script:_BackendCapture = $CaptureFile
    # WHY: the array must be flat. `('mount', $MountArgs)` nests $MountArgs as one
    #   System.Object[] element and Start-Process rejects that. Concatenating keeps it flat.
    $proc = Start-Process -FilePath $RcloneBin -ArgumentList (@('mount') + $MountArgs) `
        -NoNewWindow -PassThru -RedirectStandardError $CaptureFile
    $Script:_BackendRclonePid = $proc.Id
    $proc
}

# Prints exactly one of: present, absent:not-listed, unknown:dir-unreadable.
#
# WHY three tokens and not a bool. Windows has no mount table, so the state is inferred
#   from the mount-point directory, and a directory this process may not read lists as
#   empty. A count test would report that as not-mounted and send the operator to the
#   remote. backend_probe_state in mount-backend-darwin.sh prints the same three tokens,
#   and the attach loop in rclone-mount.ps1 tests the `unknown:` prefix alone.
#
# WHY the reparse-point test stays as an additional reason to answer present, and why a
#   try/catch wraps Get-ChildItem rather than testing $item or counting $Error: Get-Item
#   returns a DirectoryInfo for an unreadable directory so `-not $item` never fires, and
#   $Error is a process-wide sink any earlier command can have written to.
#
# UNVERIFIED on Windows: that a WinFsp directory mount is exposed as a reparse point on
#   the mount point itself. Confirm on a real host with (Get-Item -Force <mount point>).Attributes.
function Mount-Backend-ProbeState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MountPoint)

    if (-not (Test-Path -LiteralPath $MountPoint)) {
        Write-Output 'absent:not-listed'
        return
    }

    $item = Get-Item -LiteralPath $MountPoint -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Output 'present'
        return
    }

    try {
        $items = @(Get-ChildItem -LiteralPath $MountPoint -ErrorAction Stop)
    } catch {
        Write-Output 'unknown:dir-unreadable'
        return
    }

    if ($items.Count -gt 0) {
        Write-Output 'present'
        return
    }
    Write-Output 'absent:not-listed'
}

function Mount-Backend-Unmount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountPoint)

    # check-suppress:suppression_doc: no rclone process running is the normal case; Get-Process throws instead of returning an empty set
    Get-Process -Name 'rclone' -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($MountPoint) } |
        # check-suppress:suppression_doc: the process can exit between enumeration and this call, making the stop a no-op
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Mount-Backend-Repair {
    [CmdletBinding()]
    param()

    # check-suppress:suppression_doc: repair is a no-op when WinFsp is absent, which the -not $svc test below selects
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc) {
        # WHY: Write-Output, not Write-Host, whose information stream a scheduled task's
        #   stdout/stderr redirection does not collect. Unreferenced today, so the message
        #   is the only outcome signal a future caller gets.
        Write-Output "Restarting WinFsp.Launcher service..."
        # WHY: the success line follows the restart, so it prints only when the restart
        #   actually returned.
        try {
            Restart-Service -Name 'WinFsp.Launcher' -Force
        } catch {
            Write-Output "WinFsp.Launcher service restart failed: $_"
            return
        }
        Write-Output "WinFsp.Launcher service restarted."
    } else {
        Write-Warning "WinFsp.Launcher service not found."
    }
}

function Mount-Backend-ProviderRefusal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$CaptureFile)

    if (-not (Test-Path $CaptureFile)) { return $false }
    # check-suppress:suppression_doc: an unreadable capture file yields $null, and -match against $null is $false, the correct probe verdict
    $content = Get-Content -Raw $CaptureFile -ErrorAction SilentlyContinue
    $content -match 'WinFsp.*not found|winfsp.*failed|FUSE.*not available'
}
