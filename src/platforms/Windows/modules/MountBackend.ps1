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
    param([Parameter(Mandatory)][string]$Class)
    $Class -in @('provider-refusal', 'io-transient')
}

# Mount-Backend-Prepare — ensure WinFsp is installed and its launcher is running.
function Mount-Backend-Prepare {
    [CmdletBinding()]
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

# Mount-Backend-Args — emit Windows-specific rclone mount flags.
function Mount-Backend-Args {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][bool]$ReadOnly,
        [string]$ExtraArgs = ''
    )

    $args = @($Remote, $MountPoint,
        '--vfs-cache-mode', 'full',
        '--vfs-cache-max-age', '1h',
        '--dir-cache-time', '5m',
        '--poll-interval', '1m',
        '--log-level', 'NOTICE')

    if ($ReadOnly) { $args += '--read-only' }

    if ($ExtraArgs) {
        $args += ($ExtraArgs -split '\s+' | Where-Object { $_ })
    }

    $args
}

# Mount-Backend-Mount — invoke rclone with the resolved flags.
function Mount-Backend-Mount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RcloneBin,
        [Parameter(Mandatory)][string[]]$Args,
        [Parameter(Mandatory)][string]$CaptureFile
    )

    $Script:_BackendCapture = $CaptureFile
    $proc = Start-Process -FilePath $RcloneBin -ArgumentList ('mount', $Args) `
        -NoNewWindow -PassThru -RedirectStandardError $CaptureFile
    $Script:_BackendRclonePid = $proc.Id
    $proc
}

# Mount-Backend-Probe — check if the volume is live.
function Mount-Backend-Probe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountPoint)

    if (Test-Path $MountPoint) {
        $items = Get-ChildItem -Path $MountPoint -ErrorAction SilentlyContinue
        return ($null -ne $items -and $items.Count -gt 0)
    }
    return $false
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
    param([string]$MountPoint = '')

    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Restarting WinFsp.Launcher service..."
        Restart-Service -Name 'WinFsp.Launcher' -Force -ErrorAction SilentlyContinue
        Write-Host "WinFsp.Launcher service restarted."
    } else {
        Write-Warning "WinFsp.Launcher service not found."
    }
}

# Mount-Backend-ProviderRefusal — whether the failure was a provider refusal.
function Mount-Backend-ProviderRefusal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CaptureFile)

    if (-not (Test-Path $CaptureFile)) { return $false }
    $content = Get-Content -Raw $CaptureFile -ErrorAction SilentlyContinue
    $content -match 'WinFsp.*not found|winfsp.*failed|FUSE.*not available'
}
