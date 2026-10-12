<#
.SYNOPSIS
    Cloud-mount core runner (Windows): bounded retry with backoff, classification,
    and health records. Dispatches to MountBackend.ps1.
.DESCRIPTION
    Environment injected by the wrapper or caller: NUCLEUS_RCLONE_REMOTE,
    NUCLEUS_RCLONE_MOUNT_POINT, NUCLEUS_RCLONE_ARGS, NUCLEUS_RCLONE_BIN,
    NUCLEUS_RCLONE_READ_ONLY, NUCLEUS_CLOUD_MOUNT_INSTANCE, NUCLEUS_MOUNT_ATTEMPTS,
    NUCLEUS_MOUNT_BACKOFF, NUCLEUS_MOUNT_ATTACH_SECONDS.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

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

Initialize-HealthRecord -Instance $instance

# Last attempt's capture tail, bound while the file still exists so the blocked
# records written below can carry rclone's own words. Empty means the run
# captured nothing worth keeping.
$failureOutput = ''

$prepareRc = Mount-Backend-Prepare -Instance $instance
if ($prepareRc -eq 20) {
    # WHY: Write-Output, not Write-Host: this script is the body of a scheduled task
    #   whose stdout is captured to stdout.log, while the verbose and information streams
    #   are hidden under the default preference variables, so those would silently drop
    #   the operator's mount diagnostics.  Every Write-Host below follows this same rule.
    # WHY: the notice carries the class and remedy itself. Clear-HealthRecordAll at
    #   apply deletes every health record, so a line pointing at the record names
    #   evidence that is gone by the time the log is read.
    $class = Get-HealthField -Instance $instance -Field 'class'
    $remedy = Get-HealthField -Instance $instance -Field 'remedy'
    Write-Output "$instance`: backend requires user action (class=$class): $remedy"
    exit 0
}

for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    if (Test-HealthBlocked -Instance $instance) {
        $class = Get-HealthField -Instance $instance -Field 'class'
        Write-Output "$instance`: blocked (class=$class); not attempting"
        exit 0
    }

    Write-Output "$instance`: mount attempt $attempt/$attempts"

    # WHY: the instance id is folder-qualified, so raw it would nest this file under a
    #   directory that does not exist and -RedirectStandardError would fail terminally.
    #   Get-HealthSafeInstanceName owns that mapping.
    $captureFile = Join-Path $env:TEMP "rclone-capture-$(Get-HealthSafeInstanceName -Instance $instance)-$PID.txt"

    $mountArgs = Mount-Backend-ArgumentList -Remote $remote -MountPoint $mountPoint -ReadOnly $readOnly -ExtraArgs $rcloneArgs

    $proc = Mount-Backend-Mount -RcloneBin $rcloneBin -MountArgs $mountArgs -CaptureFile $captureFile

    $live = $false
    $start = [DateTimeOffset]::Now
    # The classification below keys on how the wait ended, not on the probe token:
    # the two disagree whenever the loop breaks out on a dead child after a readable
    # absent answer.
    $probeState = ''
    $exitReason = ''
    # WHY Mount-Backend-ProbeState, which keeps the third value. A two-valued answer
    #   is $false both for a live mount and for a directory this process may not read,
    #   and this loop treats that $false as a running service and deletes the capture
    #   file, so an unknown state must poll like the absent state and let the budget
    #   end the run.
    while (([DateTimeOffset]::Now - $start).TotalSeconds -lt $attachSeconds) {
        $probeState = Mount-Backend-ProbeState -MountPoint $mountPoint
        if ($probeState -eq 'present') {
            $live = $true
            $exitReason = 'attached'
            break
        }
        # WHY: a mount that dies during startup would be polled for the whole budget
        #   while the capture file already held the reason. Process.HasExited is exact,
        #   unlike the POSIX `kill -0`: Windows reaps the child, so a dead child never
        #   reads as alive.
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
        # WHY: same reason as the evidence field, applied to the output tail: a
        #   record that recovered must not keep the last failure's words.
        Set-HealthField -Instance $instance -Field 'failureOutput' -Value $null

        # WHY the poll rather than one blocking WaitForExit(): a still-running
        #   rclone is the mount serving, so the loop keeps waiting on the live
        #   process and only the 10s timeout wakes it. Once the child is gone the
        #   reap gets its own bound, because WaitForExit also completes redirected-
        #   output draining, which can outlive the process; a reap that does not
        #   finish within 10s is reported and abandoned so a wedged child cannot
        #   hold the scheduled task open forever. The capture file survives the
        #   wait because the record may need its tail below.
        while (-not $proc.HasExited) {
            # check-suppress:suppression_doc: the completion flag is re-read through HasExited on the next pass
            $null = $proc.WaitForExit(10000)
        }
        if (-not $proc.WaitForExit(10000)) {
            Write-Output "$instance`: warning: exited rclone did not finish shutting down within 10s; abandoning the wait"
        }
        $exitCode = $proc.ExitCode

        Set-HealthLastExitCode -Instance $instance $exitCode

        # WHY the post-attach death tail: the capture holds the only words a death
        #   after attaching leaves, and deleting it before the wait, the old order,
        #   destroyed them. The normal set is 0, a clean exit after a clean
        #   unmount, and 1, the exit a terminated child reports on Windows, the
        #   counterpart of POSIX's 143; the runner's own Pester suite pins that
        #   pair, so a stand-in exiting 1 after attaching must leave the record
        #   reading healthy. Any other status gets the tail POSIX writes.
        if ($exitCode -notin @(0, 1)) {
            $deathTail = if (Test-Path -LiteralPath $captureFile) {
                @(Get-Content -LiteralPath $captureFile -Tail 20)
            } else { @() }
            # WHY the guard: an absent or empty tail joins to an empty string, while
            #   the field's convention (service-health.sh) is to null an absent tail,
            #   so failureOutput is never written as an empty string.
            $deathOutput = $deathTail -join "`n"
            if ($deathOutput) {
                Set-HealthField -Instance $instance -Field 'failureOutput' -Value $deathOutput
            } else {
                Set-HealthField -Instance $instance -Field 'failureOutput' -Value $null
            }
            Write-Output "$instance`: mount died after attaching with status $exitCode"
        }
        # check-suppress:suppression_doc: best-effort capture cleanup; the record carries the tail when the death was abnormal
        Remove-Item -Path $captureFile -ErrorAction SilentlyContinue

        Mount-Backend-Unmount -MountPoint $mountPoint
        Write-Output "$instance`: mount exited with status $exitCode"
        exit $exitCode
    }

    $class = Mount-Backend-Class -CaptureFile $captureFile

    # WHY: an unreadable mount point says nothing about the mount. Mount-Backend-Class
    #   answers mount-failed when rclone's output carries no cause, which would blame
    #   the mount for a read nobody could make. io-transient costs a retry instead of
    #   stopping the run on a read that never completed.
    #   The case is keyed on the ending because the ending cannot tell a budget expiry
    #   from a child that died first, and both endings take the same arm, which still
    #   tests the probe token. An ending this code cannot place lands in the default
    #   arm with the unreadable directory rather than keeping the classifier's answer.
    #   There is no `attached` arm: the wait only ends attached when $live is true, and
    #   the success path exits before this switch.
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

    # Stop rclone if still running: grace first, then Kill, each bounded.
    if (-not $proc.HasExited) {
        # WHY the two bounded waits: the POSIX runner TERMs and polls for up to
        #   10s, then KILLs and polls again before abandoning a child that
        #   survives both. Kill() is this platform's only stop, so the first
        #   wait is the grace a dying child gets to exit on its own, and the
        #   second bounds the reap after Kill. A child still alive after both
        #   is reported and left alone rather than blocking the task forever.
        if (-not $proc.WaitForExit(10000)) {
            $proc.Kill()
            if (-not $proc.WaitForExit(5000)) {
                Write-Output "$instance`: warning: rclone did not exit within 5s of Kill(); abandoning the wait"
            }
        }
    }

    Write-Output "$instance`: attempt $attempt failed (class=$class, $remedy)"

    # WHY: the tail is taken while the capture file still exists. Every later
    #   branch may delete it, and the blocked records written below are the only
    #   place the exact error survives; twenty lines hold the failure and its
    #   immediate context without turning the record into a log. The POSIX runner
    #   binds the same tail with `tail -n 20`.
    $tailLines = if (Test-Path -LiteralPath $captureFile) {
        @(Get-Content -LiteralPath $captureFile -Tail 20)
    } else { @() }
    $failureOutput = $tailLines -join "`n"

    # WHY keep the capture file only on the unreadable-mount-point path: there the
    #   class is one this runner chose, not one rclone's output supports, so the file
    #   is the only record of what the mount was doing. The record names the path
    #   because log lines rotate, and it holds one path, not a list, so a run that
    #   keeps a file on several attempts leaves earlier ones unreachable. Removing
    #   this attempt's file never clears the field, because the field can only name
    #   an earlier attempt's file.
    if ($probeUnknown) {
        Set-HealthField -Instance $instance -Field 'evidence' -Value $captureFile
        Write-Output "$instance`: rclone output kept at $captureFile"
    } else {
        # check-suppress:suppression_doc: best-effort capture cleanup; the class in the record is the whole diagnosis on this path
        Remove-Item -Path $captureFile -ErrorAction SilentlyContinue
    }

    # Terminal class: stop immediately.
    if (-not (Mount-Backend-IsTransient -Class $class)) {
        Set-HealthBlocked -Instance $instance -Class $class -Remedy $remedy -FailureOutput $failureOutput
        exit 0
    }

    # Transient: backoff and retry.
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

# All attempts exhausted: blocked.
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
Set-HealthBlocked -Instance $instance -Class $finalClass -Remedy (Mount-Backend-Remedy -Class $finalClass) -FailureOutput $failureOutput
Write-Output "$instance`: all $attempts attempts exhausted; blocked"
exit 0
