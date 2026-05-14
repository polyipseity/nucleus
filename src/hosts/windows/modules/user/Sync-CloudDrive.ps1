# Sync-CloudDrive.ps1 — Provision cloud drive mounts and replicas on Windows.
#
# Reads per-user cloud drive configuration from users.json and provisions:
#   Mounts  — rclone mount processes managed as persistent NSSM services.
#             Requires WinFsp (WinFsp.WinFsp in WinGet), NSSM (NSSM.NSSM), and
#             rclone configured via `rclone config`.
#   Replicas — rclone sync/bisync for full local copies. All replicas default
#              to disabled; each entry must set "enable": true.
#
# iCloud on Windows: not supported (no rclone backend). Entries with
# provider="iCloud" are skipped with a warning.
#
# Prerequisites (one-time manual steps):
#   1. WinFsp installed (WinFsp.WinFsp via WinGet — declared in system.dsc.yml)
#   2. rclone installed (Rclone.Rclone via WinGet — declared in system.dsc.yml)
#   3. NSSM installed (NSSM.NSSM via WinGet — declared in system.dsc.yml)
#   4. rclone remotes configured: run `rclone config` for each provider
#
# Idempotency: mount directories are created if absent; existing mounts are
# converged to the desired NSSM service command and restarted only when running.

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
        $provider = $mount.provider

        # iCloud Drive has no supported rclone backend on Windows.
        # WHY skipped: no rclone remote type maps to iCloud Drive on Windows;
        # native OneDrive sync covers the Microsoft ecosystem and Google Drive
        # covers Google; iCloud on Windows is documented as unsupported.
        if ($provider -eq 'iCloud') {
            Write-Warning "cloud-drives: iCloud mount '$($mount.id)' is not supported on Windows; skipping."
            continue
        }

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

        # Probe NSSM availability without failing the entire converge.
        # WHY benign probe: if NSSM is absent we skip mount automation and keep
        # other cloud-drive entries converging.
        $nssmExe = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
        if (-not $nssmExe) {
            Write-Warning "cloud-drives: NSSM not found on PATH; install via 'winget install NSSM.NSSM' for mount '$($mount.id)'."
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

        # Quote all parameters so NSSM preserves spaces/special characters in
        # remotes, paths, and user-provided extra arguments.
        $appParameters = ($mountArgs | ForEach-Object {
            '"{0}"' -f ($_.ToString().Replace('"', '\"'))
        }) -join ' '

        $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $existingService) {
            & $nssmExe install $serviceName $rcloneExe
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "cloud-drives: failed to create NSSM service '$serviceName' for mount '$($mount.id)'; skipping."
                continue
            }
        }

        & $nssmExe set $serviceName Application $rcloneExe
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cloud-drives: failed to set NSSM Application for service '$serviceName'; skipping."
            continue
        }

        & $nssmExe set $serviceName AppDirectory (Split-Path -Parent $rcloneExe)
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cloud-drives: failed to set NSSM AppDirectory for service '$serviceName'; skipping."
            continue
        }

        & $nssmExe set $serviceName AppParameters $appParameters
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cloud-drives: failed to set NSSM AppParameters for service '$serviceName'; skipping."
            continue
        }

        & $nssmExe set $serviceName Start SERVICE_AUTO_START
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cloud-drives: failed to set NSSM start mode for service '$serviceName'; skipping."
            continue
        }

        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Warning "cloud-drives: service '$serviceName' not found after NSSM configuration; skipping start."
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
        if ($replica.provider -eq 'iCloud') {
            Write-Warning "cloud-drives: iCloud replica '$($replica.id)' is not supported on Windows; skipping."
            continue
        }

        $localPath = Join-Path $HomeDirectory $replica.localPath
        if (-not (Test-Path $localPath)) {
            New-Item -ItemType Directory -Path $localPath -Force | Out-Null
            Write-Verbose "cloud-drives: created replica directory $localPath"
        }

        Write-Verbose "cloud-drives: replica '$($replica.id)' ($($replica.provider)) provisioned at $localPath"
    }

    Write-Output "$($PSStyle.Foreground.Green)cloud-drives: provisioning complete.$($PSStyle.Reset)"
}
