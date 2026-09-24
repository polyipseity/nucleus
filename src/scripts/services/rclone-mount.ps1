<#
.SYNOPSIS
    Cloud-mount core runner (Windows).
.DESCRIPTION
    Bounded retry with backoff, classification, health records.
    Dispatches to MountBackend.ps1. No OS/FUSE/supervisor names.

    Environment (injected by the wrapper or caller):
      NUCLEUS_RCLONE_REMOTE_NAME, NUCLEUS_RCLONE_REMOTE,
      NUCLEUS_RCLONE_MOUNT_POINT, NUCLEUS_RCLONE_ARGS,
      NUCLEUS_CLOUD_MOUNT_INSTANCE.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\platforms\Windows\modules\ServiceHealth.ps1"
. "$PSScriptRoot\..\platforms\Windows\modules\MountBackend.ps1"

$instance = $env:NUCLEUS_CLOUD_MOUNT_INSTANCE
if (-not $instance) { throw 'NUCLEUS_CLOUD_MOUNT_INSTANCE not set' }
$remote = $env:NUCLEUS_RCLONE_REMOTE
if (-not $remote) { throw 'NUCLEUS_RCLONE_REMOTE not set' }
$mountPoint = $env:NUCLEUS_RCLONE_MOUNT_POINT
if (-not $mountPoint) { throw 'NUCLEUS_RCLONE_MOUNT_POINT not set' }
$rcloneArgs = $env:NUCLEUS_RCLONE_ARGS
$rcloneBin = if ($env:NUCLEUS_RCLONE_BIN) { $env:NUCLEUS_RCLONE_BIN } else { 'rclone' }
$readOnly = $env:NUCLEUS_RCLONE_READ_ONLY -eq 'true'
$attempts = if ($env:NUCLEUS_MOUNT_ATTEMPTS) { [int]$env:NUCLEUS_MOUNT_ATTEMPTS } else { 3 }
$attachSeconds = if ($env:NUCLEUS_MOUNT_ATTACH_SECONDS) { [int]$env:NUCLEUS_MOUNT_ATTACH_SECONDS } else { 45 }
$backoffCsv = if ($env:NUCLEUS_MOUNT_BACKOFF) { $env:NUCLEUS_MOUNT_BACKOFF } else { '20,40' }
$backoffSchedule = $backoffCsv -split ',' | ForEach-Object { [int]$_.Trim() }

# Initialize health record.
Health-Init -Instance $instance

# Backend prepare.
$prepareRc = Mount-Backend-Prepare -Instance $instance
if ($prepareRc -eq 20) {
    Write-Host "$instance`: backend requires user action; see health record"
    exit 0
}

# Bounded retry loop.
for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    if (Health-IsBlocked -Instance $instance) {
        $class = Health-Get -Instance $instance -Field 'class'
        Write-Host "$instance`: blocked (class=$class); not attempting"
        exit 0
    }

    Write-Host "$instance`: mount attempt $attempt/$attempts"

    $captureFile = Join-Path $env:TEMP "rclone-capture-$instance-$PID.txt"

    # Build mount args.
    $mountArgs = Mount-Backend-Args -Remote $remote -MountPoint $mountPoint -ReadOnly $readOnly -ExtraArgs $rcloneArgs

    # Start rclone mount.
    $proc = Start-Process -FilePath $rcloneBin -ArgumentList ('mount', $mountArgs) `
        -NoNewWindow -PassThru -RedirectStandardError $captureFile -Wait:$false

    # Wait for mount to appear.
    $live = $false
    $start = [DateTimeOffset]::Now
    while (([DateTimeOffset]::Now - $start).TotalSeconds -lt $attachSeconds) {
        if (Mount-Backend-Probe -MountPoint $mountPoint) {
            $live = $true
            break
        }
        Start-Sleep -Seconds 1
    }

    if ($live) {
        Health-SetRunning -Instance $instance
        Health-RecordSuccess -Instance $instance
        Health-IncrementRuns -Instance $instance

        # Wait for rclone to exit.
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        Health-SetLastExit -Instance $instance $exitCode
        Mount-Backend-Unmount -MountPoint $mountPoint
        Write-Host "$instance`: mount exited with status $exitCode"
        exit $exitCode
    }

    # Classify failure.
    $class = Mount-Backend-Class -CaptureFile $captureFile
    $remedy = Mount-Backend-Remedy -Class $class

    # Kill rclone if still running.
    if (-not $proc.HasExited) {
        $proc.Kill()
        $proc.WaitForExit()
    }

    Write-Host "$instance`: attempt $attempt failed (class=$class, $remedy)"

    # Terminal class — stop immediately.
    if (-not (Mount-Backend-IsTransient -Class $class)) {
        Health-SetBlocked -Instance $instance -Class $class -Remedy $remedy
        Remove-Item -Path $captureFile -ErrorAction SilentlyContinue
        exit 0
    }

    # Transient — backoff and retry.
    Remove-Item -Path $captureFile -ErrorAction SilentlyContinue
    if ($attempt -lt $attempts) {
        $backoffIdx = [Math]::Min($attempt - 1, $backoffSchedule.Count - 1)
        $backoff = $backoffSchedule[$backoffIdx]
        Write-Host "$instance`: retrying in ${backoff}s"
        Start-Sleep -Seconds $backoff
    }
}

# All attempts exhausted — blocked.
Health-SetBlocked -Instance $instance -Class 'mount-failed' -Remedy (Mount-Backend-Remedy -Class 'mount-failed')
Write-Host "$instance`: all $attempts attempts exhausted; blocked"
exit 0
