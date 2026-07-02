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
function Sync-CloudDrive {
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
    # Legacy cleanup — remove old Servy-managed mount services
    # ------------------------------------------------------------------
    $oldMountServices = Get-Service -Name 'nucleus-cloud-mount-*' -ErrorAction SilentlyContinue
    foreach ($oldSvc in $oldMountServices) {
        Stop-Service -Name $oldSvc.Name -ErrorAction SilentlyContinue
        sc.exe delete $oldSvc.Name
        Write-Verbose "cloud-drives: cleaned up legacy Servy service '$($oldSvc.Name)'"
    }

    # ------------------------------------------------------------------
    # Mounts
    # ------------------------------------------------------------------
    $enabledMounts = $mounts | Where-Object { $_.enable -eq $true }
    foreach ($mount in $enabledMounts) {
        $localPath = Join-Path $HomeDirectory $mount.localPath
        if (Test-Path -LiteralPath $localPath) {
            $existingMountPath = Get-Item -LiteralPath $localPath -Force
            $mountPathIsReparsePoint = ($existingMountPath.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

            # Enforce real directory mountpoints on Windows for parity with
            # POSIX hosts and to avoid stale symlink/junction targets.
            if ($mountPathIsReparsePoint -or -not $existingMountPath.PSIsContainer) {
                Remove-Item -LiteralPath $localPath -Recurse -Force
                New-Item -ItemType Directory -Path $localPath -Force | Out-Null
                Write-Verbose "cloud-drives: replaced legacy mount reparse/non-directory path with managed directory $localPath"
            }
        }
        else {
            New-Item -ItemType Directory -Path $localPath -Force | Out-Null
            Write-Verbose "cloud-drives: created mount directory $localPath"
        }

        # Verify rclone remote is configured before attempting to mount.
        $remoteName = $mount.remoteName
        if (-not $remoteName) {
            Write-Warning "cloud-drives: mount '$($mount.id)' has no remoteName configured; skipping."
            continue
        }

        $remotePath = if ($mount.remotePath) { $mount.remotePath } else { '/' }

        # Probe for rclone command availability without failing the whole apply.
        # WHY benign probe: a mount can be intentionally declared before the
        # package is installed; this function warns and skips that entry.
        $rcloneExe = (Get-Command rclone -ErrorAction SilentlyContinue)?.Source
        if (-not $rcloneExe) {
            Write-Warning "cloud-drives: rclone not found on PATH; install via 'winget install Rclone.Rclone'."
            continue
        }

        # Suppress stderr only for this probe so invalid/missing remotes do not
        # emit noisy warnings during expected discovery runs.
        # WHY safe: we immediately check exit code and remote presence below.
        $remoteList = & $rcloneExe listremotes 2>$null
        $remoteListExitCode = $LASTEXITCODE
        if ($remoteListExitCode -ne 0) {
            Write-Warning "cloud-drives: failed to list rclone remotes for mount '$($mount.id)' (exit $remoteListExitCode); skipping."
            continue
        }

        $remoteConfigured = $remoteList | Select-String -SimpleMatch "${remoteName}:"
        if (-not $remoteConfigured) {
            Write-Warning "cloud-drives: rclone remote '$remoteName' not configured; run 'rclone config' then re-apply."
            continue
        }

        # Create working directory for mount wrapper scripts and logs.
        $cloudDriveDir = Join-Path $env:LOCALAPPDATA 'nucleus\cloud-drive'
        $null = New-Item -Path $cloudDriveDir -ItemType Directory -Force
        $logDir = Get-NucleusLogDir
        $mountLogDir = Join-Path $logDir "cloud-drive-mount-$($mount.id)"
        $null = New-Item -Path $mountLogDir -ItemType Directory -Force

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

        $mountArgs = @(
            'mount'
            $remoteSpec
            $localPath
            '--vfs-cache-mode', 'full'
            '--vfs-cache-max-age', '1h'
            '--dir-cache-time', '5m'
            '--poll-interval', '1m'
            '--log-level', 'ERROR'
        )

        if ($mount.provider -eq 'iCloud') {
            $mountArgs += '--iclouddrive-service', $iCloudService
        }

        if (-not $readWrite) {
            $mountArgs += '--read-only'
        }

        if ($mount.extraArgs) {
            $mountArgs += @($mount.extraArgs | Where-Object { $_ })
        }

        # Write a PowerShell wrapper script that passes the rclone config
        # password via env var (the file is user-accessible since the schtask
        # runs as the logged-in user) and invokes rclone mount.
        $taskName = "NucleusCloudMount-$($mount.id)"
        $taskPath = '\NucleusCloudMount\'
        $logFile = Join-Path $mountLogDir "combined.log"
        $wrapperPath = Join-Path $cloudDriveDir "mount-$($mount.id).ps1"
        $rclonePassFile = Join-Path $HomeDirectory '.config\nucleus\secrets\rclone-config-pass'

        $wrapperLines = [System.Collections.ArrayList]@()
        $null = $wrapperLines.Add("# Generated by Sync-CloudDrive.ps1")
        $null = $wrapperLines.Add("# Task: $taskName")
        if (Test-Path -Path $rclonePassFile -PathType Leaf) {
            $escapedPassFile = $rclonePassFile.Replace("'", "''")
            $null = $wrapperLines.Add("`$env:RCLONE_CONFIG_PASS = (Get-Content '{0}' -Raw).Trim()" -f $escapedPassFile)
        }
        $escapedRclone = $rcloneExe.Replace("'", "''")
        $escapedLogFile = $logFile.Replace("'", "''")
        # Quote each arg for single-quoted PowerShell strings.
        $quotedArgs = ($mountArgs | ForEach-Object {
            $str = $_.ToString()
            if ($str -match '[\s"''@()`$|;]') {
                "'{0}'" -f $str.Replace("'", "''")
            }
            else {
                $str
            }
        }) -join ' '
        $null = $wrapperLines.Add("& '{0}' {1} *>> '{2}'" -f $escapedRclone, $quotedArgs, $escapedLogFile)
        Set-Content -Path $wrapperPath -Value ($wrapperLines -join "`r`n") -Force -Encoding UTF8

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
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

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
                Remove-Item -LiteralPath $localPath -Recurse -Force
                New-Item -ItemType Directory -Path $localPath -Force | Out-Null
                Write-Verbose "cloud-drives: replaced legacy replica reparse/non-directory path with managed directory $localPath"
            }
        }
        else {
            New-Item -ItemType Directory -Path $localPath -Force | Out-Null
            Write-Verbose "cloud-drives: created replica directory $localPath"
        }

        Write-Verbose "cloud-drives: replica '$($replica.id)' ($($replica.provider)) provisioned at $localPath"
    }

    Write-Output "$($PSStyle.Foreground.Green)cloud-drives: provisioning complete.$($PSStyle.Reset)"
}
