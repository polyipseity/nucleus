<#
.SYNOPSIS
    Mount backend for Windows: WinFsp.
.DESCRIPTION
    Implements Mount-Backend-* functions for the cloud-mount core runner.
    All WinFsp specifics live here — the core runner never mentions them.
.PARAMETER Instance
    Service instance key for health record writes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Script:_BackendCapture = $null
$Script:_BackendRclonePid = $null

# Mount-Backend-Class — classify a failure from stderr capture.
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

# Mount-Backend-Remedy — return the remedy text for a class.
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

# Mount-Backend-IsTransient — return true if the class is transient (retryable).
function Mount-Backend-IsTransient {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Class)
    $Class -in @('provider-refusal', 'io-transient')
}

# Mount-Backend-Prepare — ensure WinFsp is installed and its launcher is running.
function Mount-Backend-Prepare {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Instance)

    # Check WinFsp is installed.
    # check-suppress:suppression_doc: a missing command throws; the -not test on the next line is the absence probe
    $winfsp = Get-Command 'winfsp-x64.dll' -ErrorAction SilentlyContinue
    if (-not $winfsp) {
        $regPath = 'HKLM:\SOFTWARE\WOW6432Node\WinFsp'
        if (-not (Test-Path $regPath)) {
            $regPath = 'HKLM:\SOFTWARE\WinFsp'
        }
        if (-not (Test-Path $regPath)) {
            # WinFsp not installed.
            . "$PSScriptRoot\ServiceHealth.ps1"
            Set-HealthBlocked -Instance $Instance -Class 'provider-refusal' -Remedy 'install WinFsp via winget install WinFsp.WinFsp'
            return 20
        }
    }

    # Ensure WinFsp Launcher service is running.
    # check-suppress:suppression_doc: an absent service leaves $svc null, so the -and guard below skips the start and not-running is the answer
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        # WHY: the refusal is reported through the module's own channel.  rclone-mount.ps1 has
        #   no try/catch and handles only rc 20, so an escaping exception kills the mount loop
        #   before any health record exists and leaves the watchdog a record it cannot act on.
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

# Mount-Backend-ArgumentList — emit Windows-specific rclone mount flags.
function Mount-Backend-ArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][bool]$ReadOnly,
        [string]$ExtraArgs = ''
    )

    # WHY: $rcloneFlags, not $args — $args is the automatic variable, and
    #   reassigning it has undesired side effects.
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

# Mount-Backend-Mount — invoke rclone with the resolved flags.
function Mount-Backend-Mount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RcloneBin,
        # WHY: $MountArgs, not $Args — $args is the automatic variable.
        [Parameter(Mandatory)][string[]]$MountArgs,
        [Parameter(Mandatory)][string]$CaptureFile
    )

    $Script:_BackendCapture = $CaptureFile
    # WHY: the array must be FLAT.  `('mount', $MountArgs)` uses the comma operator, which
    #   nests $MountArgs as a single element (System.Object[]), and Start-Process rejects it:
    #   "Cannot convert 'System.Object[]' to the type 'System.String' required by
    #   parameter 'ArgumentList'".  Concatenating keeps one flat string array.
    $proc = Start-Process -FilePath $RcloneBin -ArgumentList (@('mount') + $MountArgs) `
        -NoNewWindow -PassThru -RedirectStandardError $CaptureFile
    $Script:_BackendRclonePid = $proc.Id
    $proc
}

# Mount-Backend-ProbeState — report the mount state of a mount point as a token.
# Prints exactly one of: present, absent:not-listed, unknown:dir-unreadable.
# Returns nothing; the caller reads the token from the success stream.
#
# WHY three tokens and not a bool.  The question is mount state, and Windows has no
#   mount table, so the answer is inferred from the mount-point directory.  A
#   directory this process may not read lists as zero entries, so a count test
#   answers not-mounted for it, and the attach loop then records a failure whose
#   cause is a permission and sends the operator to the remote.
#   backend_probe_state in mount-backend-darwin.sh prints the same three tokens, and
#   the attach loop in rclone-mount.ps1 tests the `unknown:` prefix alone, so the
#   reason after the prefix is this platform's own.
#
# WHY the reparse-point test is kept rather than replaced.  A WinFsp directory mount
#   is expected to be a reparse point in its own right, and that assumption cannot be
#   confirmed from here, so it stays as an ADDITIONAL reason to answer present.  If it
#   holds, an empty-but-mounted remote root stops being reported dead; if it does not,
#   the answer is the previous status quo.  Answering present for everything is not an
#   option, because the transition back to not-mounted is what makes revival work.
#
# WHY a try/catch rather than a null check or a count of $Error.  Get-Item returns a
#   DirectoryInfo for a directory this process may not read, so `-not $item` never
#   fires; and $Error is a process-wide sink that any earlier command can have written
#   to, so a count taken across this call would attribute someone else's error to it.
#   The thrown exception is scoped to the one call that failed.  The POSIX side makes
#   the same choice from the same shape, keying on `ls -A`'s own exit status.
#
# UNVERIFIED on Windows: that a WinFsp DIRECTORY mount is exposed as a reparse point
#   (and therefore carries FileAttributes.ReparsePoint on the mount-point directory
#   itself).  Confirm on a real Windows host by starting a mount and inspecting
#   (Get-Item -Force <mount point>).Attributes.  Until then the content check remains
#   the effective signal for a non-empty remote root.
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

# Mount-Backend-Unmount — release the volume.
function Mount-Backend-Unmount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountPoint)

    # Kill any rclone processes using this mount point.
    # check-suppress:suppression_doc: no rclone process running is the normal case; Get-Process throws instead of returning an empty set
    Get-Process -Name 'rclone' -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($MountPoint) } |
        # check-suppress:suppression_doc: the process can exit between enumeration and this call, making the stop a no-op
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Mount-Backend-Repair — restart WinFsp Launcher service.
function Mount-Backend-Repair {
    [CmdletBinding()]
    param()

    # check-suppress:suppression_doc: repair is a no-op when WinFsp is absent, which the -not $svc test below selects
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc) {
        # WHY: Write-Output, not Write-Host — Write-Host goes to the information stream,
        #   which a scheduled task's stdout/stderr redirection does not collect, and the
        #   verbose/information streams are hidden under the default preference variables,
        #   so the restart notice would be lost.  This function is currently unreferenced;
        #   keep the output on the success stream if a caller is added.
        Write-Output "Restarting WinFsp.Launcher service..."
        # WHY: the success line follows the restart rather than preceding it, so it is only
        #   emitted when the restart actually returned.  This function is unreferenced and
        #   has no return-code contract, so the message is the only outcome signal it has.
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

# Mount-Backend-ProviderRefusal — whether the failure was a provider refusal.
function Mount-Backend-ProviderRefusal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$CaptureFile)

    if (-not (Test-Path $CaptureFile)) { return $false }
    # check-suppress:suppression_doc: an unreadable capture file yields $null, and -match against $null is $false, the correct probe verdict
    $content = Get-Content -Raw $CaptureFile -ErrorAction SilentlyContinue
    $content -match 'WinFsp.*not found|winfsp.*failed|FUSE.*not available'
}
