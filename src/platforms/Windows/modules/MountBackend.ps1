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
    $winfsp = Get-Command 'winfsp-x64.dll' -ErrorAction SilentlyContinue
    if (-not $winfsp) {
        $regPath = 'HKLM:\SOFTWARE\WOW6432Node\WinFsp'
        if (-not (Test-Path $regPath)) {
            $regPath = 'HKLM:\SOFTWARE\WinFsp'
        }
        if (-not (Test-Path $regPath)) {
            # WinFsp not installed.
            . "$PSScriptRoot\ServiceHealth.ps1"
            Health-SetBlocked -Instance $Instance -Class 'provider-refusal' -Remedy 'install WinFsp via winget install WinFsp.WinFsp'
            return 20
        }
    }

    # Ensure WinFsp Launcher service is running.
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Start-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
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

# Mount-Backend-Probe — report whether the mount point is a LIVE MOUNT.
# Returns $true when mounted, $false when not mounted.
#
# WHY: this asks about MOUNT STATE, never alone about directory contents.  An empty
#   remote root is a legitimate state (a freshly created cloud folder), and reporting
#   it as dead makes the runner retry `mountAttempts` times and leave the service
#   permanently blocked at mount-failed on a mount that actually succeeded.  Linux
#   answers the same question through the mount table (mount-backend-linux.sh ->
#   svc_mount_table_contains) and macOS through diskutil; Windows has no mount table,
#   so it asks this host's mount state and keeps the content check as a SECOND
#   signal.
#
# WHY the union rather than a replacement: the reparse-point test is an assumption
#   about WinFsp that cannot be confirmed from here, so it is added as an ADDITIONAL
#   reason to call a path mounted.  If the assumption holds, empty-but-mounted starts
#   working; if it does not, behaviour is exactly the previous status quo.  Treating
#   everything as mounted is NOT an option - the transition back to not-mounted is
#   what makes revival work.
#
# UNVERIFIED on Windows: that a WinFsp DIRECTORY mount is exposed as a reparse point
#   (and therefore carries FileAttributes.ReparsePoint on the mount-point directory
#   itself).  Confirm on a real Windows host by starting a mount and inspecting
#   (Get-Item -Force <mount point>).Attributes.  Until then the content check remains
#   the effective signal for a non-empty remote root.
function Mount-Backend-Probe {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$MountPoint)

    if (-not (Test-Path -LiteralPath $MountPoint)) {
        return $false
    }

    # A WinFsp directory mount is expected to be a reparse point in its own right.
    $item = Get-Item -LiteralPath $MountPoint -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $true
    }

    # check-suppress:suppression_doc: an unreadable or empty directory is the not-mounted answer, decided by the content test immediately below.
    $items = @(Get-ChildItem -Path $MountPoint -ErrorAction SilentlyContinue)
    return ($items.Count -gt 0)
}

# Mount-Backend-Unmount — release the volume.
function Mount-Backend-Unmount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountPoint)

    # Kill any rclone processes using this mount point.
    Get-Process -Name 'rclone' -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($MountPoint) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Mount-Backend-Repair — restart WinFsp Launcher service.
function Mount-Backend-Repair {
    [CmdletBinding()]
    param()

    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc) {
        # WHY: Write-Output, not Write-Host — Write-Host goes to the information stream,
        #   which a scheduled task's stdout/stderr redirection does not collect, and the
        #   verbose/information streams are hidden under the default preference variables,
        #   so the restart notice would be lost.  This function is currently unreferenced;
        #   keep the output on the success stream if a caller is added.
        Write-Output "Restarting WinFsp.Launcher service..."
        Restart-Service -Name 'WinFsp.Launcher' -Force -ErrorAction SilentlyContinue
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
    $content = Get-Content -Raw $CaptureFile -ErrorAction SilentlyContinue
    $content -match 'WinFsp.*not found|winfsp.*failed|FUSE.*not available'
}
