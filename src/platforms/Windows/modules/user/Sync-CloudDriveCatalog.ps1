<#
.SYNOPSIS
  Provision cloud drive mounts and replicas on Windows.

.DESCRIPTION
  Reads per-user cloud drive configuration from users.json and provisions:
    Mounts  — rclone mount processes managed as logon scheduled tasks under
              \NucleusCloudMount\. Requires WinFsp (WinFsp.WinFsp in WinGet)
              and rclone configured via `rclone config`.
    Replicas — rclone sync/bisync for full local copies. All replicas default
               to disabled; each entry must set "enable": true.

  iCloud on Windows is handled through the rclone iclouddrive backend when the
  user config provides a configured remoteName (for example "iCloud").

  Each enabled mount gets a generated wrapper script at
  %LOCALAPPDATA%\nucleus\cloud-drive\mount-<id>.ps1 that sets
  $env:RCLONE_CONFIG_PASS from the secrets file and invokes rclone mount.

  Prerequisites (one-time manual steps):
    1. WinFsp installed (WinFsp.WinFsp via WinGet — declared in system/packages.dsc.yml)
    2. rclone installed (Rclone.Rclone via WinGet — declared in system/packages.dsc.yml)
    3. rclone remotes configured: run `rclone config` for each provider

.PARAMETER UserConfig
  Per-user configuration hashtable from users.json. Must contain a cloudDrives
  key with mounts and replicas arrays.

.PARAMETER HomeDirectory
  Absolute path to the user's home directory.

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure
#>

# WHY: the mount instance id is the health-record key, and the watchdog resolves it
#   through the shared scheduled-task mapping.  Reusing that mapping here keeps the
#   writer and the reader on one construction site instead of two.
. (Join-Path -Path $PSScriptRoot -ChildPath '..\Get-NucleusServiceInstance.ps1')

function Sync-CloudDriveCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$UserConfig,

        [Parameter(Mandatory)]
        [string]$HomeDirectory
    )

    $cloudDrivesConfig = $UserConfig.cloudDrives
    if (-not $cloudDrivesConfig) {
        Write-Verbose "cloud-drives: no cloudDrives config for this user; skipping."
        return
    }

    $mounts  = @($cloudDrivesConfig.mounts  | Where-Object { $_ })
    $replicas = @($cloudDrivesConfig.replicas | Where-Object { $_ })

    # ------------------------------------------------------------------
    # Mounts
    # ------------------------------------------------------------------
    # WHY: mounts default to enabled when `enable` is omitted, so the test is shared
    #   with the declared-instance filter (Test-NucleusMountEnabled) rather than being
    #   a second `-eq $true` copy that would drop mounts the watchdog still expects.
    #   Replicas below are deliberately different: their submodule defaults to false.
    $enabledMounts = $mounts | Where-Object { Test-NucleusMountEnabled -Mount $_ }

    # WHY: cloud-drive.lifecycle in services.json is the single definition of the
    #   mount retry policy.  Deriving these here keeps Windows from carrying a second
    #   copy of the same numbers; the POSIX twin derives them in cloud-drives.nix.
    $servicesJsonPath = Join-Path $env:NUCLEUS_REPO_ROOT 'src\modules\services.json'
    $servicesRegistry = Get-Content -Path $servicesJsonPath -Raw | ConvertFrom-Json -AsHashtable
    $mountLifecycle = $servicesRegistry['cloud-drive'].lifecycle
    $mountAttempts = [string]$mountLifecycle.mountAttempts
    $mountBackoff = (@($mountLifecycle.mountRetryBackoffSeconds) | ForEach-Object { [string]$_ }) -join ','
    $mountAttachSeconds = [string]$mountLifecycle.mountAttachTimeoutSeconds
    if (-not $mountAttempts -or -not $mountBackoff -or -not $mountAttachSeconds) {
        throw "cloud-drives: cloud-drive.lifecycle is incomplete (mountAttempts/mountRetryBackoffSeconds/mountAttachTimeoutSeconds) in $servicesJsonPath"
    }

    foreach ($mount in $enabledMounts) {
        $localPath = Join-Path $HomeDirectory $mount.localPath
        if (Test-Path -LiteralPath $localPath) {
            $existingMountPath = Get-Item -LiteralPath $localPath -Force
            $mountPathIsReparsePoint = ($existingMountPath.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

            # Enforce real directory mountpoints on Windows for parity with
            # POSIX hosts and to avoid stale symlink/junction targets.
            if ($mountPathIsReparsePoint -or -not $existingMountPath.PSIsContainer) {
                throw "cloud-drives: mount path '$localPath' is not a managed directory; fix manually and re-apply"
            }
        }
        else {
            New-Item -ItemType Directory -Path $localPath -Force > $null
            Write-Verbose "cloud-drives: created mount directory $localPath"
        }

        # Verify rclone remote is configured before attempting to mount.
        $remoteName = $mount.remoteName
        if (-not $remoteName) {
            Write-NucleusWarning -CommandName 'cloud-drives' "mount '$($mount.id)' has no remoteName configured; skipping."
            continue
        }

        $remotePath = if ($mount.remotePath) { $mount.remotePath } else { '/' }

        # check-suppress:suppression_doc: probe -- rclone may not be installed; $null check handles absence.
        $rcloneExe = (Get-Command rclone -ErrorAction SilentlyContinue)?.Source
        if (-not $rcloneExe) {
            Write-NucleusWarning -CommandName 'cloud-drives' "rclone not found on PATH; install via 'winget install Rclone.Rclone'."
            continue
        }

        # Suppress stderr only for this probe so invalid/missing remotes do not
        # emit noisy warnings during expected discovery runs.
        # WHY: safe: we immediately check exit code and remote presence below.
        $remoteList = & $rcloneExe listremotes 2>$null  # check-suppress:suppression_doc: probe -- remote may not be configured; $LASTEXITCODE checked below
        $remoteListExitCode = $LASTEXITCODE
        if ($remoteListExitCode -ne 0) {
            Write-NucleusWarning -CommandName 'cloud-drives' "failed to list rclone remotes for mount '$($mount.id)' (exit $remoteListExitCode); skipping."
            continue
        }

        $remoteConfigured = $remoteList | Select-String -SimpleMatch "${remoteName}:"
        if (-not $remoteConfigured) {
            Write-NucleusWarning -CommandName 'cloud-drives' "rclone remote '$remoteName' not configured; run 'rclone config' then re-apply."
            continue
        }

        # Create working directory for mount wrapper scripts and logs.
        $cloudDriveDir = Join-Path $env:LOCALAPPDATA 'nucleus\cloud-drive'
        $null = New-Item -Path $cloudDriveDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
        $logDir = Get-NucleusLogDir
        $mountLogDir = Join-Path $logDir "cloud-drive-mount-$($mount.id)"
        $null = New-Item -Path $mountLogDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

        $remoteSpec = "${remoteName}:${remotePath}"
        # Pass the iCloud service explicitly on every mount so entry behavior
        # follows users.json even if the shared remote default is different.
        $iCloudService = if ($mount.provider -eq 'iCloud' -and $mount.iCloudService) {
            [string]$mount.iCloudService
        }
        else {
            'drive'
        }
        $readWrite = if ($null -ne $mount.readWrite) { [bool]$mount.readWrite } else { $true }

        # WHY: this list carries only the per-mount EXTRAS, never `mount`, the remote
        #   spec, the mount point, the VFS flags, --log-level or --read-only: the mount
        #   backend owns those and composes them itself (Mount-Backend-Args).  Sending
        #   the whole argument list instead made the backend append it verbatim, so
        #   rclone received a stray `mount` plus a duplicated remote spec, mount point
        #   and VFS flags.  POSIX draws the same line (cloud-drives.nix extraArgsList ->
        #   NUCLEUS_RCLONE_ARGS), so both hosts keep ONE owner for the canonical flags.
        $mountExtraArgs = @()
        if ($mount.provider -eq 'iCloud') {
            $mountExtraArgs += '--iclouddrive-service', $iCloudService
        }

        # WHY: the wrapper must carry a literal resolved NOW.  The generated script runs
        #   in a fresh scope where $mount has no value, so a deferred `if ($mount.readOnly)`
        #   evaluated to writable for every mount.  $readWrite is this file's one way of
        #   reading the setting (registry field readWrite), and the mapping mirrors POSIX
        #   (cloud-drives.nix: readWrite -> READ_ONLY false/true).
        $readOnlyLiteral = if ($readWrite) { 'false' } else { 'true' }

        if ($mount.extraArgs) {
            $mountExtraArgs += @($mount.extraArgs | Where-Object { $_ })
        }

        # Write a PowerShell wrapper script that passes the rclone config
        # password via env var (the file is user-accessible since the schtask
        # runs as the logged-in user) and invokes rclone mount.
        $taskName = "NucleusCloudMount-$($mount.id)"
        $taskPath = '\NucleusCloudMount\'
        # WHY: the health-record key must be the id the watchdog resolves for this
        #   scheduled task (folder-qualified), not the bare registry id - otherwise the
        #   runner writes a record the watchdog never reads and loop detection never runs.
        $instanceId = Get-NucleusInstanceId -TaskFolder $taskPath -TaskName $taskName
        # WHY: stdout and stderr get separate files. logging.capture selects which streams
        # are captured, never the destination shape (house default: the pair).
        $stdoutLogFile = Join-Path $mountLogDir "stdout.log"
        $stderrLogFile = Join-Path $mountLogDir "stderr.log"
        $wrapperPath = Join-Path $cloudDriveDir "mount-$($mount.id).ps1"
        $rclonePassFile = Join-Path $HomeDirectory 'AppData\Local\nucleus\secrets\rclone-config-pass'

        # check-suppress:embedded-content: exception 1 (data-driven/generated content) -- per-mount env var setup for the shared runner
        $runnerPath = Join-Path $env:NUCLEUS_REPO_ROOT 'src\scripts\services\rclone-mount.ps1'
        $passLine = ''
        if (Test-Path -Path $rclonePassFile -PathType Leaf) {
            $escapedPassFile = $rclonePassFile.Replace("'", "''")
            $passLine = "`$env:RCLONE_CONFIG_PASS = (Get-Content '$escapedPassFile' -Raw).Trim()`r`n"
        }

        # WHY: every interpolated value below lands inside a single-quoted PowerShell
        #   literal in the generated wrapper, so an apostrophe in any of them (a profile
        #   such as C:\Users\O'Brien, a remote name, an extra arg) would terminate the
        #   literal early and leave the wrapper unparseable - the scheduled task then
        #   fails silently inside a hidden window.  Escaping follows the
        #   $escapedPassFile idiom above.  Code-derived values (readOnlyLiteral, the
        #   lifecycle numerics) cannot contain an apostrophe and are emitted as-is.
        # WHY: the remote value is the REMOTE SPEC, not the bare remote name: POSIX
        #   sets NUCLEUS_RCLONE_REMOTE to "${remoteName}:${remotePath}"
        #   (cloud-drives.nix).  Every current registry entry uses remotePath "/",
        #   where the two forms are equivalent, so this is inert today - but a
        #   non-root remotePath would otherwise be silently dropped and the root
        #   would be mounted instead.
        $escapedRemoteName = ([string]$remoteSpec).Replace("'", "''")
        $escapedMountPoint = ([string]$localPath).Replace("'", "''")
        $escapedInstanceId = ([string]$instanceId).Replace("'", "''")
        $escapedArgs = ([string]($mountExtraArgs -join "`r`n")).Replace("'", "''")
        $escapedRcloneExe = ([string]$rcloneExe).Replace("'", "''")
        $escapedRunnerPath = ([string]$runnerPath).Replace("'", "''")
        $escapedStdoutLogFile = ([string]$stdoutLogFile).Replace("'", "''")
        $escapedStderrLogFile = ([string]$stderrLogFile).Replace("'", "''")

        # WHY: the resolved absolute rclone path is conveyed because the task runs
        #   `pwsh.exe -NoProfile`, so a bare `rclone` resolves only when it happens to be
        #   on the user's registry PATH.  POSIX reads the same variable but is safe via the
        #   wrapper's runtimeInputs PATH; Windows has no equivalent guarantee.
        # WHY: the wrapper redirects the runner's output to per-instance stdout/stderr
        #   files under <root>/logs - a captured service writes each stream to its own
        #   file, and without this the mount's output is discarded entirely.
        $wrapperContent = "# Auto-generated by Sync-CloudDriveCatalog.ps1`r`n`$env:NUCLEUS_RCLONE_REMOTE = '$escapedRemoteName'`r`n`$env:NUCLEUS_RCLONE_MOUNT_POINT = '$escapedMountPoint'`r`n`$env:NUCLEUS_CLOUD_MOUNT_INSTANCE = '$escapedInstanceId'`r`n`$env:NUCLEUS_RCLONE_READ_ONLY = '$readOnlyLiteral'`r`n`$env:NUCLEUS_RCLONE_ARGS = '$escapedArgs'`r`n`$env:NUCLEUS_RCLONE_BIN = '$escapedRcloneExe'`r`n`$env:NUCLEUS_MOUNT_ATTEMPTS = '$mountAttempts'`r`n`$env:NUCLEUS_MOUNT_BACKOFF = '$mountBackoff'`r`n`$env:NUCLEUS_MOUNT_ATTACH_SECONDS = '$mountAttachSeconds'`r`n`$passLine`& '$escapedRunnerPath' 1>> '$escapedStdoutLogFile' 2>> '$escapedStderrLogFile'`r`n"
        Set-Content -Path $wrapperPath -Value $wrapperContent -Force -Encoding UTF8

        # Register a logon scheduled task that runs the wrapper in a hidden
        # window so no console appears at startup.
        $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
            $env:USERNAME
        }
        else {
            "$($env:USERDOMAIN)\$($env:USERNAME)"
        }

        $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-WindowStyle Hidden -NoLogo -ExecutionPolicy Bypass -NoProfile -File `"$wrapperPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

        # check-suppress:suppression_doc: probe -- task may not be registered yet; $null check handles absence.
        $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Verbose "cloud-drives: unregistered previous scheduled task '$taskName'"
        }

        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
        Write-Verbose "cloud-drives: registered scheduled task '$taskName' for mount '$($mount.id)'."
    }

    # ------------------------------------------------------------------
    # Replicas (stub — enabled replicas emit an informational message)
    # ------------------------------------------------------------------
    $enabledReplicas = $replicas | Where-Object { $_.enable -eq $true }
    foreach ($replica in $enabledReplicas) {
        $localPath = Join-Path $HomeDirectory $replica.localPath
        if (Test-Path -LiteralPath $localPath) {
            $existingReplicaPath = Get-Item -LiteralPath $localPath -Force
            $replicaPathIsReparsePoint = ($existingReplicaPath.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

            # Keep Windows replica targets as managed directories. The macOS-only
            # iCloudReplica symlink exception does not apply on Windows.
            if ($replicaPathIsReparsePoint -or -not $existingReplicaPath.PSIsContainer) {
                throw "cloud-drives: replica path '$localPath' is not a managed directory; fix manually and re-apply"
            }
        }
        else {
            New-Item -ItemType Directory -Path $localPath -Force > $null
            Write-Verbose "cloud-drives: created replica directory $localPath"
        }

        Write-Verbose "cloud-drives: replica '$($replica.id)' ($($replica.provider)) provisioned at $localPath"
    }

    Write-NucleusInfo -CommandName 'cloud-drives' "provisioning complete."
}
