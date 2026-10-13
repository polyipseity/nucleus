<#
.SYNOPSIS
    Minimal cloud-mount supervisor (Windows).
.DESCRIPTION
    Windows half of the three-host mount contract shared with
    src/scripts/services/rclone-mount.sh. Each pass launches rclone in the
    foreground with the instance's arguments, streams its output into the
    retained mount log, and after any exit waits RetrySeconds before mounting
    again. The scheduled task owns revival at logon and its restart-on-failure
    settings back the loop; there are no health records, no classification,
    and no attempt budget by design. The log file is the failure surface and
    the loop is the supervision, because a supervisor rather than the command
    must own the backoff (rclone/rclone#9899).
.PARAMETER Instance
    Folder-qualified instance id (for example
    '\NucleusCloudMount\NucleusCloudMount-iCloud') used in the loop's own
    messages.
.PARAMETER LogFile
    Full path of the retained mount log. Created with its parent directories
    on first start; rclone's merged output appends here and the file is never
    deleted by this wrapper.
.PARAMETER MountPoint
    Directory rclone mounts onto. The file system driver tears the mount down
    with its process, so there is no clean pass: process death is the
    unmount.
.PARAMETER RemoteSpec
    rclone remote specification, for example 'GoogleDrive:/'.
.PARAMETER RcloneArgs
    Remaining rclone flags, forwarded verbatim after the remote spec and
    mount point.
.PARAMETER RetrySeconds
    Delay between one rclone exit and the next attempt. Defaults to 30 to
    match launchd ThrottleInterval and systemd RestartSec on the POSIX hosts.
.EXAMPLE
    rclone-mount.ps1 -Instance '\NucleusCloudMount\NucleusCloudMount-iCloud' -LogFile 'C:\Users\guest\AppData\Local\nucleus\logs\cloud-drive-mount-iCloud\mount.log' -MountPoint 'C:\Users\guest\clouds\iCloud' -RemoteSpec 'iCloud:/' -RcloneArgs @('--iclouddrive-service', 'drive')
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Instance,

    [Parameter(Mandatory)]
    [string]$LogFile,

    [Parameter(Mandatory)]
    [string]$MountPoint,

    [Parameter(Mandatory)]
    [string]$RemoteSpec,

    [Parameter()]
    [string[]]$RcloneArgs = @(),

    # WHY exposed with a default: the cadence is the policy (30s, identical to
    #   launchd ThrottleInterval and systemd RestartSec) and stays the default
    #   everywhere; the parameter exists so the contract test can observe a
    #   second attempt without waiting a real thirty seconds.
    [Parameter()]
    [int]$RetrySeconds = 30
)

$ErrorActionPreference = 'Stop'

$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
    $null = New-Item -ItemType Directory -Path $logDir -Force
}

$fullArgs = @($RemoteSpec, $MountPoint) + $RcloneArgs

while ($true) {
    # WHY 2>&1 into one retained file: this is the design's single failure
    #   surface per instance (mirrors the POSIX wrapper's `>> log 2>&1`);
    #   Tee keeps the stream flowing to the caller, so a manual run shows
    #   rclone's output live while the file keeps it.
    & rclone mount @fullArgs 2>&1 | Tee-Object -FilePath $LogFile -Append
    $exitCode = $LASTEXITCODE
    # WHY Write-Output: this script is the body of a scheduled task, so stdout
    #   is the captured channel for the wrapper's own notices.
    Write-Output "$Instance`: rclone exited with status $exitCode; retrying in ${RetrySeconds}s"
    Start-Sleep -Seconds $RetrySeconds
}
