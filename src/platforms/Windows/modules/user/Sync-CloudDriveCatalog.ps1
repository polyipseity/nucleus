<#
.SYNOPSIS
  Provision cloud drive mounts and replicas on Windows.

.DESCRIPTION
  Mounts become logon scheduled tasks under \NucleusCloudMount\ whose generated
  wrapper sets $env:RCLONE_CONFIG_PASS and invokes rclone mount. Replicas are
  rclone sync copies, all disabled unless the entry sets "enable": true.

  Prerequisite, declared in system/packages.dsc.yml: WinFsp.WinFsp and
  Rclone.Rclone, plus `rclone config` per provider.
#>

# WHY: the mount instance id is the health-record key, and the watchdog resolves
#   it through the same scheduled-task mapping, so writer and reader share one
#   construction site.
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

    # WHY: mounts default to enabled when 'enable' is omitted, so the declared-instance
    #   filter is reused instead of a second `-eq $true` copy that would drop mounts
    #   the watchdog still expects. Replicas default to false.
    $enabledMounts = $mounts | Where-Object { Test-NucleusMountEnabled -Mount $_ }

    # WHY: cloud-drive.lifecycle in services.json is the single definition of the
    #   retry policy; POSIX derives the same numbers in cloud-drives.nix.
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

            if ($mountPathIsReparsePoint -or -not $existingMountPath.PSIsContainer) {
                throw "cloud-drives: mount path '$localPath' is not a managed directory; fix manually and re-apply"
            }
        }
        else {
            New-Item -ItemType Directory -Path $localPath -Force > $null
            Write-Verbose "cloud-drives: created mount directory $localPath"
        }

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

        # WHY 2>$null is safe: the exit code and remote presence are checked below.
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

        $cloudDriveDir = Join-Path $env:LOCALAPPDATA 'nucleus\cloud-drive'
        $null = New-Item -Path $cloudDriveDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
        $logDir = Get-NucleusLogDir
        $mountLogDir = Join-Path $logDir "cloud-drive-mount-$($mount.id)"
        $null = New-Item -Path $mountLogDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

        $remoteSpec = "${remoteName}:${remotePath}"
        # WHY pass it per mount: entry behaviour then follows users.json even when the
        # shared remote default differs.
        $iCloudService = if ($mount.provider -eq 'iCloud' -and $mount.iCloudService) {
            [string]$mount.iCloudService
        }
        else {
            'drive'
        }
        $readWrite = if ($null -ne $mount.readWrite) { [bool]$mount.readWrite } else { $true }

        # WHY extras only: the backend owns `mount`, the remote spec, the mount point,
        #   the VFS flags, --log-level and --read-only. Sending the whole list made the
        #   backend append it verbatim and rclone saw a stray `mount`. POSIX draws the
        #   same line (cloud-drives.nix extraArgsList -> NUCLEUS_RCLONE_ARGS).
        $mountExtraArgs = @()
        if ($mount.provider -eq 'iCloud') {
            $mountExtraArgs += '--iclouddrive-service', $iCloudService
        }

        # WHY resolve now: the generated script runs in a fresh scope where $mount has no
        #   value, so a deferred `if ($mount.readOnly)` made every mount writable.
        #   Mapping mirrors POSIX (cloud-drives.nix: readWrite -> READ_ONLY).
        $readOnlyLiteral = if ($readWrite) { 'false' } else { 'true' }

        if ($mount.extraArgs) {
            $mountExtraArgs += @($mount.extraArgs | Where-Object { $_ })
        }

        # WHY a generated wrapper: the schtask runs as the logged-in user, so the config
        #   password has to arrive through a user-readable env var rather than a secret file.
        $taskName = "NucleusCloudMount-$($mount.id)"
        $taskPath = '\NucleusCloudMount\'
        # WHY folder-qualified: that is the id the watchdog resolves for this task, and
        #   the bare registry id would write a record loop detection never reads.
        $instanceId = Get-NucleusInstanceId -TaskFolder $taskPath -TaskName $taskName
        # WHY the split: logging.capture picks which streams are captured, never the
        #   destination shape, and a captured service writes each stream to its own file.
        $stdoutLogFile = Join-Path $mountLogDir "stdout.log"
        $stderrLogFile = Join-Path $mountLogDir "stderr.log"
        $wrapperPath = Join-Path $cloudDriveDir "mount-$($mount.id).ps1"
        $rclonePassFile = Join-Path $HomeDirectory 'AppData\Local\nucleus\secrets\rclone-config-pass'

        # check-suppress:embedded-content: exception 1 (data-driven/generated content) -- per-mount env var setup for the shared runner
        $runnerPath = Join-Path $env:NUCLEUS_REPO_ROOT 'src\scripts\services\rclone-mount.ps1'
        # WHY the concatenation: PSUseDeclaredVarsMoreThanAssignments does not see a
        #   variable read only inside an interpolated string, so folding $passLine back
        #   into the wrapper literal reports it as unused. Emitted text is identical.
        $passLine = if (Test-Path -Path $rclonePassFile -PathType Leaf) {
            $escapedPassFile = $rclonePassFile.Replace("'", "''")
            "`$env:RCLONE_CONFIG_PASS = (Get-Content '$escapedPassFile' -Raw).Trim()`r`n"
        } else {
            ''
        }

        # WHY escape: every value lands inside a single-quoted PowerShell literal in the
        #   wrapper, so an apostrophe (a path like C:\Users\O'Brien, a remote name, an
        #   extra arg) would end the literal early and fail the task silently in a hidden
        #   window. Code-derived values cannot contain one and are emitted as-is.
        # WHY the remote spec: POSIX sets NUCLEUS_RCLONE_REMOTE to
        #   "${remoteName}:${remotePath}" (cloud-drives.nix). Inert today because every
        #   entry uses remotePath "/", but a non-root path would otherwise be dropped.
        $escapedRemoteName = ([string]$remoteSpec).Replace("'", "''")
        $escapedMountPoint = ([string]$localPath).Replace("'", "''")
        $escapedInstanceId = ([string]$instanceId).Replace("'", "''")
        $escapedArgs = ([string]($mountExtraArgs -join "`r`n")).Replace("'", "''")
        $escapedRcloneExe = ([string]$rcloneExe).Replace("'", "''")
        $escapedRunnerPath = ([string]$runnerPath).Replace("'", "''")
        $escapedStdoutLogFile = ([string]$stdoutLogFile).Replace("'", "''")
        $escapedStderrLogFile = ([string]$stderrLogFile).Replace("'", "''")

        # WHY the resolved path: the task runs `pwsh.exe -NoProfile`, so a bare `rclone`
        #   resolves only when the registry PATH happens to carry it. POSIX is safe
        #   through the wrapper's runtimeInputs; Windows has no equivalent.
        # WHY the redirects: without them the mount's output is discarded entirely.
        $wrapperContent = "# Auto-generated by Sync-CloudDriveCatalog.ps1`r`n`$env:NUCLEUS_RCLONE_REMOTE = '$escapedRemoteName'`r`n`$env:NUCLEUS_RCLONE_MOUNT_POINT = '$escapedMountPoint'`r`n`$env:NUCLEUS_CLOUD_MOUNT_INSTANCE = '$escapedInstanceId'`r`n`$env:NUCLEUS_RCLONE_READ_ONLY = '$readOnlyLiteral'`r`n`$env:NUCLEUS_RCLONE_ARGS = '$escapedArgs'`r`n`$env:NUCLEUS_RCLONE_BIN = '$escapedRcloneExe'`r`n`$env:NUCLEUS_MOUNT_ATTEMPTS = '$mountAttempts'`r`n`$env:NUCLEUS_MOUNT_BACKOFF = '$mountBackoff'`r`n`$env:NUCLEUS_MOUNT_ATTACH_SECONDS = '$mountAttachSeconds'`r`n" +
            $passLine +
            "& '$escapedRunnerPath' 1>> '$escapedStdoutLogFile' 2>> '$escapedStderrLogFile'`r`n"
        Set-Content -Path $wrapperPath -Value $wrapperContent -Force -Encoding UTF8

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

    $enabledReplicas = $replicas | Where-Object { $_.enable -eq $true }
    foreach ($replica in $enabledReplicas) {
        $localPath = Join-Path $HomeDirectory $replica.localPath
        if (Test-Path -LiteralPath $localPath) {
            $existingReplicaPath = Get-Item -LiteralPath $localPath -Force
            $replicaPathIsReparsePoint = ($existingReplicaPath.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

            # WHY no symlink exception: the iCloudReplica symlink is macOS-only.
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
