<#
.SYNOPSIS
    Cloud-mount core runner (Windows).
.DESCRIPTION
    Bounded retry with backoff, classification, health records.
    Dispatches to MountBackend.ps1. No OS/FUSE/supervisor names.

    Environment (injected by the wrapper or caller):
      NUCLEUS_RCLONE_REMOTE, NUCLEUS_RCLONE_MOUNT_POINT, NUCLEUS_RCLONE_ARGS,
      NUCLEUS_RCLONE_BIN, NUCLEUS_RCLONE_READ_ONLY,
      NUCLEUS_CLOUD_MOUNT_INSTANCE, NUCLEUS_MOUNT_ATTEMPTS,
      NUCLEUS_MOUNT_BACKOFF, NUCLEUS_MOUNT_ATTACH_SECONDS.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ── Resolve repo root ──────────────────────────────────────────────────────
# Same bootstrap as src/scripts/services/service-watchdog.ps1: NUCLEUS_REPO_ROOT
# wins (the machine-wide value apply.ps1 writes), and the PSScriptRoot walk
# covers a direct run from the live checkout.
$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) {
    $env:NUCLEUS_REPO_ROOT
} else {
    Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

$ModulesDir = Join-Path $RepoRoot 'src\platforms\Windows\modules'

. (Join-Path $ModulesDir 'ServiceHealth.ps1')
. (Join-Path $ModulesDir 'MountBackend.ps1')

$instance = $env:NUCLEUS_CLOUD_MOUNT_INSTANCE
if (-not $instance) { throw 'NUCLEUS_CLOUD_MOUNT_INSTANCE not set' }
$remote = $env:NUCLEUS_RCLONE_REMOTE
if (-not $remote) { throw 'NUCLEUS_RCLONE_REMOTE not set' }
$mountPoint = $env:NUCLEUS_RCLONE_MOUNT_POINT
if (-not $mountPoint) { throw 'NUCLEUS_RCLONE_MOUNT_POINT not set' }
$rcloneArgs = $env:NUCLEUS_RCLONE_ARGS
$rcloneBin = if ($env:NUCLEUS_RCLONE_BIN) { $env:NUCLEUS_RCLONE_BIN } else { 'rclone' }
$readOnly = $env:NUCLEUS_RCLONE_READ_ONLY -eq 'true'
# The lifecycle policy is single-sourced from cloud-drive.lifecycle in
# services.json and injected by the generator, so these three are REQUIRED.
# WHY: a hardcoded default here is a second policy definition that can silently
#   drift from the registry, and the POSIX runner consumes the same three with
#   `:?` (required, no fallback). A missing value must fail loudly on both hosts.
$attemptsRaw = $env:NUCLEUS_MOUNT_ATTEMPTS
if (-not $attemptsRaw) { throw 'NUCLEUS_MOUNT_ATTEMPTS not set' }
$attempts = [int]$attemptsRaw
$attachSecondsRaw = $env:NUCLEUS_MOUNT_ATTACH_SECONDS
if (-not $attachSecondsRaw) { throw 'NUCLEUS_MOUNT_ATTACH_SECONDS not set' }
$attachSeconds = [int]$attachSecondsRaw
$backoffCsv = $env:NUCLEUS_MOUNT_BACKOFF
if (-not $backoffCsv) { throw 'NUCLEUS_MOUNT_BACKOFF not set' }
$backoffSchedule = $backoffCsv -split ',' | ForEach-Object { [int]$_.Trim() }

# Initialize health record.
Initialize-HealthRecord -Instance $instance

# Backend prepare.
$prepareRc = Mount-Backend-Prepare -Instance $instance
if ($prepareRc -eq 20) {
    # WHY: Write-Output, not Write-Host — this script is the body of a scheduled task
    #   whose stdout is captured to stdout.log, while the verbose and information streams
    #   are hidden under the default preference variables, so those would silently drop
    #   the operator's mount diagnostics.  Every Write-Host below follows this same rule.
    Write-Output "$instance`: backend requires user action; see health record"
    exit 0
}

# Bounded retry loop.
for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    if (Test-HealthBlocked -Instance $instance) {
        $class = Get-HealthField -Instance $instance -Field 'class'
        Write-Output "$instance`: blocked (class=$class); not attempting"
        exit 0
    }

    Write-Output "$instance`: mount attempt $attempt/$attempts"

    # WHY: the instance id is folder-qualified (\NucleusCloudMount\NucleusCloudMount-iCloud),
    # so it cannot be used raw in a path — the embedded separators would nest this file
    # under a directory that does not exist and -RedirectStandardError would then fail
    # terminally.  Get-HealthSafeInstanceName owns the one instance -> path-safe mapping,
    # so reuse it rather than repeating the substitution here.
    $captureFile = Join-Path $env:TEMP "rclone-capture-$(Get-HealthSafeInstanceName -Instance $instance)-$PID.txt"

    # Build mount args.
    $mountArgs = Mount-Backend-ArgumentList -Remote $remote -MountPoint $mountPoint -ReadOnly $readOnly -ExtraArgs $rcloneArgs

    # Start rclone mount through the backend's single mount entry point (POSIX delegates
    # the same way); it prepends the 'mount' subcommand itself.
    $proc = Mount-Backend-Mount -RcloneBin $rcloneBin -MountArgs $mountArgs -CaptureFile $captureFile

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
        Set-HealthRunning -Instance $instance
        Set-HealthSuccess -Instance $instance

        # Wait for rclone to exit.
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        Set-HealthLastExitCode -Instance $instance $exitCode
        Mount-Backend-Unmount -MountPoint $mountPoint
        Write-Output "$instance`: mount exited with status $exitCode"
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

    Write-Output "$instance`: attempt $attempt failed (class=$class, $remedy)"

    # Terminal class — stop immediately.
    if (-not (Mount-Backend-IsTransient -Class $class)) {
        Set-HealthBlocked -Instance $instance -Class $class -Remedy $remedy
        Remove-Item -Path $captureFile -ErrorAction SilentlyContinue
        exit 0
    }

    # Transient — backoff and retry.
    Remove-Item -Path $captureFile -ErrorAction SilentlyContinue
    if ($attempt -lt $attempts) {
        # The declared schedule is CLAMPED, never extrapolated (services.schema.json,
        # mountRetryBackoffSeconds): an attempt past the end of the list reuses the last declared value,
        # so every delay is a value services.json declares.  The POSIX runner clamps
        # identically in _cm_get_backoff; the two hosts must not diverge on this rule.
        $backoffIdx = [Math]::Min($attempt - 1, $backoffSchedule.Count - 1)
        $backoff = $backoffSchedule[$backoffIdx]
        Write-Output "$instance`: retrying in ${backoff}s"
        Start-Sleep -Seconds $backoff
    }
}

# All attempts exhausted — blocked.
Set-HealthBlocked -Instance $instance -Class 'mount-failed' -Remedy (Mount-Backend-Remedy -Class 'mount-failed')
Write-Output "$instance`: all $attempts attempts exhausted; blocked"
exit 0
