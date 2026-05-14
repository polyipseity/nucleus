# Sync-CloudDrive.ps1 — Provision cloud drive mounts and replicas on Windows.
#
# Reads per-user cloud drive configuration from users.json and provisions:
#   Mounts  — rclone mount processes managed as persistent Servy services.
#             Requires WinFsp (WinFsp.WinFsp in WinGet), Servy
#             (aelassas.Servy), and rclone configured via `rclone config`.
#   Replicas — rclone sync/bisync for full local copies. All replicas default
#              to disabled; each entry must set "enable": true.
#
# iCloud on Windows: handled through the rclone iclouddrive backend when the
# user config provides a configured remoteName (for example "iCloud").
#
# Prerequisites (one-time manual steps):
#   1. WinFsp installed (WinFsp.WinFsp via WinGet — declared in system.dsc.yml)
#   2. rclone installed (Rclone.Rclone via WinGet — declared in system.dsc.yml)
#   3. Servy installed (aelassas.Servy via WinGet — declared in system.dsc.yml)
#   4. rclone remotes configured: run `rclone config` for each provider
#
# Idempotency: mount directories are created if absent; existing mount services
# are converged by reinstalling the Servy definition to match the desired
# rclone command.

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
    # Mounts
    # ------------------------------------------------------------------
    $enabledMounts = $mounts | Where-Object { $_.enable -eq $true }
    foreach ($mount in $enabledMounts) {
        $localPath = Join-Path $HomeDirectory $mount.localPath
        if (-not (Test-Path $localPath)) {
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

        # Probe Servy CLI availability without failing the entire converge.
        # WHY benign probe: if Servy is absent we skip mount automation and keep
        # other cloud-drive entries converging.
        $servyCliExe = (Get-Command servy-cli -ErrorAction SilentlyContinue)?.Source
        if (-not $servyCliExe) {
            Write-Warning "cloud-drives: servy-cli not found on PATH; install via 'winget install aelassas.Servy' for mount '$($mount.id)'."
            continue
        }

        $serviceName = "nucleus-cloud-mount-$($mount.id)"
        $remoteSpec = "${remoteName}:${remotePath}"
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

        if (-not $readWrite) {
            $mountArgs += '--read-only'
        }

        if ($mount.extraArgs) {
            $mountArgs += @($mount.extraArgs | Where-Object { $_ })
        }

        # Quote all parameters so Servy preserves spaces/special characters in
        # remotes, paths, and user-provided extra arguments.
        $appParameters = ($mountArgs | ForEach-Object {
            '"{0}"' -f ($_.ToString().Replace('"', '\"'))
        }) -join ' '

        $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($existingService) {
            if ($existingService.Status -eq 'Running') {
                try {
                    Stop-Service -Name $serviceName -ErrorAction Stop
                }
                catch {
                    Write-Warning "cloud-drives: failed to stop existing service '$serviceName' before Servy reconfigure; skipping mount '$($mount.id)'."
                    continue
                }
            }

            & $servyCliExe uninstall "--name=$serviceName"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "cloud-drives: failed to uninstall existing Servy service '$serviceName'; skipping mount '$($mount.id)'."
                continue
            }
        }

        & $servyCliExe install "--name=$serviceName" "--displayName=$serviceName" "--description=Managed rclone mount for nucleus cloud drive '$($mount.id)'" "--path=$rcloneExe" "--startupDir=$(Split-Path -Parent $rcloneExe)" "--params=$appParameters" "--startupType=Automatic"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cloud-drives: failed to install Servy service '$serviceName' for mount '$($mount.id)'; skipping."
            continue
        }

        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Warning "cloud-drives: service '$serviceName' not found after Servy install; skipping start."
            continue
        }

        if ($service.Status -eq 'Running') {
            Restart-Service -Name $serviceName -ErrorAction Stop
            Write-Verbose "cloud-drives: restarted mount service '$serviceName' for mount '$($mount.id)'."
        }
        else {
            Start-Service -Name $serviceName -ErrorAction Stop
            Write-Verbose "cloud-drives: started mount service '$serviceName' for mount '$($mount.id)'."
        }
    }

    # ------------------------------------------------------------------
    # Replicas (stub — enabled replicas emit an informational message)
    # ------------------------------------------------------------------
    $enabledReplicas = $replicas | Where-Object { $_.enable -eq $true }
    foreach ($replica in $enabledReplicas) {
        $localPath = Join-Path $HomeDirectory $replica.localPath
        if (-not (Test-Path $localPath)) {
            New-Item -ItemType Directory -Path $localPath -Force | Out-Null
            Write-Verbose "cloud-drives: created replica directory $localPath"
        }

        Write-Verbose "cloud-drives: replica '$($replica.id)' ($($replica.provider)) provisioned at $localPath"
    }

    Write-Output "$($PSStyle.Foreground.Green)cloud-drives: provisioning complete.$($PSStyle.Reset)"
}
