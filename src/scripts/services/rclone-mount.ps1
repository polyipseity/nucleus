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

    # Wait for the volume to appear.
    $live = $false
    $start = [DateTimeOffset]::Now
    # What the last probe answered, and how this wait ended.  The two disagree
    # whenever the loop breaks out on a dead child after a readable absent answer, so
    # the classification below keys on the ending rather than inferring one from the
    # probe token.
    $probeState = ''
    $exitReason = ''
    # WHY Mount-Backend-ProbeState, which keeps the third value.  A two-valued answer
    #   is $false both for a live mount and for a directory this process may not read,
    #   and this loop acts on that $false by recording the service running and deleting
    #   the capture file, so only the three-valued answer is safe here: an unknown
    #   state falls through to the same poll the absent state takes, spending no
    #   attempt and issuing no restart of its own, and the budget below is what ends
    #   the run.
    while (([DateTimeOffset]::Now - $start).TotalSeconds -lt $attachSeconds) {
        $probeState = Mount-Backend-ProbeState -MountPoint $mountPoint
        if ($probeState -eq 'present') {
            $live = $true
            $exitReason = 'attached'
            break
        }
        # WHY: a mount that dies during startup would otherwise be polled for the whole
        #   budget before anything classified it, even though the capture file already
        #   held the reason.  Process.HasExited is the counterpart of the POSIX `kill -0`
        #   probe and, unlike it, is exact: Windows reaps the child itself, so there is
        #   no zombie window in which a dead child still reads as alive.
        if ($proc.HasExited) {
            $exitReason = 'child-exited'
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $exitReason) { $exitReason = 'budget' }

    if ($live) {
        Set-HealthRunning -Instance $instance
        Set-HealthSuccess -Instance $instance
        # WHY: reaching running ends the failure the pointer was written for, and a
        #   record still naming a retained capture file would point whoever reads it at
        #   evidence for a mount that is now healthy.
        Set-HealthField -Instance $instance -Field 'evidence' -Value $null
        # check-suppress:suppression_doc: best-effort capture cleanup; the file is this attempt's own and the record no longer names it
        Remove-Item -Path $captureFile -ErrorAction SilentlyContinue

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

    # WHY: an unreadable mount point says nothing about the mount.  Mount-Backend-Class
    #   reads rclone's output and answers mount-failed when it finds no cause there,
    #   which would blame the mount for a read nobody could make and send the operator
    #   to check the remote.  io-transient is the class whose remedy is to try again, so
    #   the unreadable probe answer overrides the classifier.
    #   The ending on its own cannot tell a budget expiry from a child that died first,
    #   so the case is keyed on the ending — but both reachable endings take the same
    #   arm, and that arm still tests the probe token, so the ending selects the arm,
    #   not the class that gets recorded.  What keying on the ending buys is the
    #   default arm: an ending this code cannot place takes the same branch as an
    #   unreadable directory, instead of keeping whatever Mount-Backend-Class answered
    #   for it.  io-transient is the safe reading of a state this code cannot place: the
    #   class whose remedy is to try again, which costs a retry, over the terminal
    #   classes, which stop the run and point the operator at the remote on the
    #   strength of a read that never completed.  There is no `attached` arm, because
    #   the wait can only end attached when $live is true, and the success path above
    #   exits at its own line before reaching this switch.
    $probeUnknown = $false
    switch ($exitReason) {
        { $_ -in @('child-exited', 'budget') } {
            if ($probeState -like 'unknown:*') {
                $probeUnknown = $true
                $class = 'io-transient'
            }
            break
        }
        default {
            $probeUnknown = $true
            $class = 'io-transient'
        }
    }
    $remedy = Mount-Backend-Remedy -Class $class

    # Kill rclone if still running.
    if (-not $proc.HasExited) {
        $proc.Kill()
        $proc.WaitForExit()
    }

    Write-Output "$instance`: attempt $attempt failed (class=$class, $remedy)"

    # WHY: the capture file is dropped on every other path because the class in the
    #   health record is the whole diagnosis there.  On the unreadable-mount-point path
    #   the class is one this runner chose rather than one rclone's output supports, so
    #   the file is the only remaining record of what the mount was doing while the read
    #   kept failing.  Kept and named rather than dropped silently; at most one file per
    #   attempt survives a run.
    #
    # WHY: the record carries the path because the log line does not suffice.  Log
    #   lines rotate, so a file nothing else points at is a file a later run cannot find.
    #
    # WHY: one field and not a list.  It names the most recent file kept, so a run that
    #   keeps a file on each of several attempts leaves the earlier ones unreachable
    #   again.  That limit is written down here so the next reader meets it in the code
    #   rather than rediscovering it.
    #
    # WHY: no clear of the evidence field accompanies the removal below.  That branch
    #   removes THIS attempt's file, and the field can only ever name an earlier
    #   attempt's kept file, so it never names the one going away.  A run that kept a
    #   file on an unreadable mount point and then reached this branch on a later
    #   attempt strands that earlier file on disk with nothing pointing at it, which is
    #   the condition the field exists to remove.
    if ($probeUnknown) {
        Set-HealthField -Instance $instance -Field 'evidence' -Value $captureFile
        Write-Output "$instance`: rclone output kept at $captureFile"
    } else {
        # check-suppress:suppression_doc: best-effort capture cleanup; the class in the record is the whole diagnosis on this path
        Remove-Item -Path $captureFile -ErrorAction SilentlyContinue
    }

    # Terminal class — stop immediately.
    if (-not (Mount-Backend-IsTransient -Class $class)) {
        Set-HealthBlocked -Instance $instance -Class $class -Remedy $remedy
        exit 0
    }

    # Transient — backoff and retry.
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
# WHY: the last attempt's own diagnosis must not be overwritten.  $class holds the last
#   attempt's classification because the loop reassigns it on every pass it makes, and
#   no other health record carries that classification out of the loop: a transient
#   attempt writes no health record at all, and the capture file kept on the
#   unreadable-mount-point path holds rclone's raw output rather than a class, so a
#   hardcoded mount-failed here would discard the one classification the run produced
#   and send the operator to the remote when what stopped the run was the budget.
#
# WHY a NUCLEUS_MOUNT_ATTEMPTS that is not a positive number is not guarded here: the
#   loop body then never runs, $class is never assigned, and the mandatory -Class
#   parameter rejects the empty value and the runner throws.  That is the loud
#   failure this prefers over writing a record whose class and remedy were invented.
#   services.schema.json pins mountAttempts to a minimum of 1 and the schema-validation
#   check step validates the file, so nothing valid reaches it.
$finalClass = if ($probeUnknown) { 'io-transient' } else { $class }
Set-HealthBlocked -Instance $instance -Class $finalClass -Remedy (Mount-Backend-Remedy -Class $finalClass)
Write-Output "$instance`: all $attempts attempts exhausted; blocked"
exit 0
