<#
.SYNOPSIS
  Synchronize enabled cloud replicas declared in src/modules/users.json.

.DESCRIPTION
  Windows counterpart to scripts/replica-bisync.sh. Reads the per-user replica
  definitions from src/modules/users.json and runs rclone sync/bisync for each
  enabled entry that has a remoteName.

  Direction handling:
    - pull          => rclone sync remote -> local
    - push          => rclone sync local  -> remote
    - bidirectional => rclone bisync local <-> remote (with one --resync retry)

  This function is safe to call from apply.ps1 as a best-effort post-apply step:
    - no-op when rclone is absent
    - no-op when no replicas are enabled for current user

.PARAMETER RepoRoot
  Repository root path.

.PARAMETER DryRun
  Prints planned rclone commands without executing them.

.PARAMETER ReplicaId
  Optional replica id filter; when provided only the matching replica runs.
#>

function Invoke-ReplicaBisync {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [switch]$DryRun,
    [string]$ReplicaId
  )

  $ErrorActionPreference = "Stop"

  # WHY early acknowledgement: PSScriptAnalyzer flags unused parameters at the
  # function scope even when they are forwarded later to helpers. Emitting a
  # dry-run banner here keeps lint strict while also making manual invocations
  # self-describing.
  if ($DryRun) {
    Write-Output "replica-bisync: running in dry-run mode (no changes will be made)"
  }

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $usersJsonPath = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\users.json"
  $cleanupConfigPath = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\configs\cloud\replica-cleanup.json"
  if (-not (Test-Path -Path $usersJsonPath -PathType Leaf)) {
    throw "replica-bisync: users registry not found at '$usersJsonPath'."
  }
  if (-not (Test-Path -Path $cleanupConfigPath -PathType Leaf)) {
    throw "replica-bisync: cleanup config not found at '$cleanupConfigPath'."
  }

  # Command presence probe: rclone may be absent on first-provision hosts.
  $rcloneCmd = Get-Command -Name "rclone" -ErrorAction SilentlyContinue
  if ($null -eq $rcloneCmd) {
    Write-Output "replica-bisync: rclone not found; skipping replica sync"
    return
  }

  # Load managed rclone config passphrase when available so encrypted
  # rclone.conf works in non-interactive sessions.
  $rclonePassPath = Join-Path -Path $HOME -ChildPath ".config\nucleus\secrets\rclone-config-pass"
  if (Test-Path -Path $rclonePassPath -PathType Leaf) {
    $passphrase = (Get-Content -Path $rclonePassPath -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not [string]::IsNullOrWhiteSpace($passphrase)) {
      $env:RCLONE_CONFIG_PASS = $passphrase
    }
  }

  $usersConfig = Get-Content -Raw -Path $usersJsonPath | ConvertFrom-Json
  $cleanupConfig = Get-Content -Raw -Path $cleanupConfigPath | ConvertFrom-Json
  $macOSMetadataFileGlobs = @($cleanupConfig.macOSMetadata.fileGlobs | ForEach-Object { [string]$_ })
  $macOSMetadataDirectoryNames = @($cleanupConfig.macOSMetadata.directoryNames | ForEach-Object { [string]$_ })
  $macOSMetadataRemoteFilterGlobs = @($cleanupConfig.macOSMetadata.remoteFilterGlobs | ForEach-Object { [string]$_ })
  $oneDriveInaccessibleRootEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($cleanupConfig.oneDrive.inaccessibleRootEntries)) {
    [void]$oneDriveInaccessibleRootEntries.Add([string]$entry)
  }
  $username = [System.Environment]::UserName

  $userConfigProperty = $usersConfig.PSObject.Properties | Where-Object { $_.Name -eq $username } | Select-Object -First 1
  if ($null -eq $userConfigProperty) {
    Write-Output "replica-bisync: no user entry for '$username' in users.json; skipping"
    return
  }

  $replicas = @($userConfigProperty.Value.cloudDrives.replicas | Where-Object {
      $_.enable -eq $true -and -not [string]::IsNullOrWhiteSpace($_.remoteName)
    })

  if ($replicas.Count -eq 0) {
    Write-Output "replica-bisync: no enabled replicas for user '$username'"
    return
  }

  if (-not [string]::IsNullOrWhiteSpace($ReplicaId)) {
    $replicas = @($replicas | Where-Object { $_.id -eq $ReplicaId })
    if ($replicas.Count -eq 0) {
      Write-Output "replica-bisync: replica id '$ReplicaId' not enabled for user '$username'"
      return
    }
  }

  function Resolve-ReplicaFilterPath {
    param(
      [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
      return $null
    }

    if ($Candidate.StartsWith('~/')) {
      return (Join-Path -Path $HOME -ChildPath $Candidate.Substring(2))
    }

    if ([System.IO.Path]::IsPathRooted($Candidate)) {
      return $Candidate
    }

    return (Join-Path -Path $HOME -ChildPath $Candidate)
  }

  function Invoke-ReplicaRcloneCommand {
    param(
      [Parameter(Mandatory)]
      [string[]]$Arguments,
      [switch]$IsDryRun
    )

    if ($IsDryRun) {
      Write-Output ("replica-bisync: [dry-run] rclone " + ($Arguments -join ' '))
      return $true
    }

    & $rcloneCmd.Source @Arguments
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    return $true
  }

  function Join-ReplicaRemoteChildPath {
    param(
      [Parameter(Mandatory)]
      [string]$RemoteRef,
      [Parameter(Mandatory)]
      [string]$ChildName
    )

    return (($RemoteRef.TrimEnd('/')) + '/' + $ChildName)
  }

  function Add-UniqueReplicaEntry {
    param(
      [Parameter(Mandatory)]
      [System.Collections.Generic.HashSet[string]]$Set,
      [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
      return
    }

    [void]$Set.Add($Value)
  }

  function Test-RemoteTopLevelPathAccessible {
    param(
      [Parameter(Mandatory)]
      [string]$RemoteRef,
      [Parameter(Mandatory)]
      [string]$EntryName,
      [switch]$IsDryRun
    )

    if ($IsDryRun) {
      return $true
    }

    $probeArgs = @(
      'lsf',
      (Join-ReplicaRemoteChildPath -RemoteRef $RemoteRef -ChildName $EntryName),
      '--max-depth', '1',
      '--disable', 'ListR',
      '--log-level', 'ERROR',
      '--retries', '1',
      '--low-level-retries', '1',
      '--timeout', '30s',
      '--contimeout', '10s',
      '--max-duration', '1m'
    )

    return (Invoke-ReplicaRcloneCommand -Arguments $probeArgs)
  }

  function Test-IsOneDriveInaccessibleRootEntry {
    param(
      [string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($EntryName)) {
      return $false
    }

    return $oneDriveInaccessibleRootEntries.Contains($EntryName.TrimEnd('/'))
  }

  function Get-OneDriveRootFilterFile {
    param(
      [Parameter(Mandatory)]
      [string]$ReplicaId,
      [Parameter(Mandatory)]
      [string]$LocalDir,
      [Parameter(Mandatory)]
      [string]$RemoteRef,
      [switch]$IsDryRun
    )

    $filterFile = [System.IO.Path]::GetTempFileName()
    $dirEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $fileEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    @($macOSMetadataRemoteFilterGlobs | ForEach-Object { "- $_" }) | Set-Content -Path $filterFile -Encoding utf8

    $remoteDirsArgs = @(
      'lsf', $RemoteRef,
      '--max-depth', '1',
      '--dirs-only',
      '--disable', 'ListR',
      '--log-level', 'ERROR',
      '--retries', '1',
      '--low-level-retries', '1',
      '--timeout', '30s',
      '--contimeout', '10s',
      '--max-duration', '1m'
    )
    $remoteDirs = if ($IsDryRun) { @() } else { & $rcloneCmd.Source @remoteDirsArgs 2>$null }
    if ($LASTEXITCODE -eq 0 -and $null -ne $remoteDirs) {
      foreach ($remoteDir in @($remoteDirs)) {
        $trimmedDir = ([string]$remoteDir).TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($trimmedDir)) {
          continue
        }

        if (Test-IsOneDriveInaccessibleRootEntry -EntryName $trimmedDir) {
          Write-Warning "replica-bisync: [$ReplicaId] skipping inaccessible OneDrive root entry '$trimmedDir'"
          continue
        }

        if (Test-RemoteTopLevelPathAccessible -RemoteRef $RemoteRef -EntryName $trimmedDir -IsDryRun:$IsDryRun) {
          Add-UniqueReplicaEntry -Set $dirEntries -Value $trimmedDir
        }
        else {
          Write-Warning "replica-bisync: [$ReplicaId] skipping inaccessible OneDrive root entry '$trimmedDir'"
        }
      }
    }

    $remoteFilesArgs = @(
      'lsf', $RemoteRef,
      '--max-depth', '1',
      '--files-only',
      '--disable', 'ListR',
      '--log-level', 'ERROR',
      '--retries', '1',
      '--low-level-retries', '1',
      '--timeout', '30s',
      '--contimeout', '10s',
      '--max-duration', '1m'
    )
    $remoteFiles = if ($IsDryRun) { @() } else { & $rcloneCmd.Source @remoteFilesArgs 2>$null }
    if ($LASTEXITCODE -eq 0 -and $null -ne $remoteFiles) {
      foreach ($remoteFile in @($remoteFiles)) {
        if (Test-IsOneDriveInaccessibleRootEntry -EntryName ([string]$remoteFile)) {
          Write-Warning "replica-bisync: [$ReplicaId] skipping inaccessible OneDrive root entry '$remoteFile'"
          continue
        }
        Add-UniqueReplicaEntry -Set $fileEntries -Value ([string]$remoteFile)
      }
    }

    if (Test-Path -Path $LocalDir -PathType Container) {
      foreach ($localEntry in Get-ChildItem -Path $LocalDir -Force -ErrorAction SilentlyContinue) {
        if (Test-IsOneDriveInaccessibleRootEntry -EntryName $localEntry.Name) {
          Write-Warning "replica-bisync: [$ReplicaId] skipping inaccessible OneDrive root entry '$($localEntry.Name)'"
          continue
        }
        if ($localEntry.PSIsContainer) {
          Add-UniqueReplicaEntry -Set $dirEntries -Value $localEntry.Name
        }
        else {
          Add-UniqueReplicaEntry -Set $fileEntries -Value $localEntry.Name
        }
      }
    }

    foreach ($dirEntry in $dirEntries) {
      Add-Content -Path $filterFile -Encoding utf8 -Value "+ /$dirEntry/"
      Add-Content -Path $filterFile -Encoding utf8 -Value "+ /$dirEntry/**"
    }
    foreach ($fileEntry in $fileEntries) {
      Add-Content -Path $filterFile -Encoding utf8 -Value "+ /$fileEntry"
    }
    Add-Content -Path $filterFile -Encoding utf8 -Value '+ /RCLONE_TEST/'
    Add-Content -Path $filterFile -Encoding utf8 -Value '+ /RCLONE_TEST/**'
    Add-Content -Path $filterFile -Encoding utf8 -Value '- **'

    return $filterFile
  }

  function Clear-LocalMacOSMetadataArtifact {
    param(
      [Parameter(Mandatory)]
      [string]$TargetDir,
      [switch]$IsDryRun
    )

    if (-not (Test-Path -Path $TargetDir -PathType Container)) {
      return
    }

    if ($IsDryRun) {
      Write-Output "replica-bisync: [dry-run] local metadata cleanup in '$TargetDir'"
      return
    }

    foreach ($pattern in $macOSMetadataFileGlobs) {
      Get-ChildItem -Path $TargetDir -Recurse -Force -File -Filter $pattern -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }

    foreach ($directoryName in $macOSMetadataDirectoryNames) {
      Get-ChildItem -Path $TargetDir -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $directoryName } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  function Clear-RemoteMacOSMetadataArtifact {
    param(
      [Parameter(Mandatory)]
      [string]$ReplicaId,
      [Parameter(Mandatory)]
      [string]$RemoteRef,
      [Parameter(Mandatory)]
      [string]$RemotePath,
      [Parameter(Mandatory)]
      [string]$Provider,
      [Parameter(Mandatory)]
      [string]$ICloudService,
      [string]$ResolvedFilterPath,
      [string]$RuntimeFilterPath,
      [Parameter(Mandatory)]
      [switch]$IsDryRun
    )

    if ($Provider -eq 'OneDrive' -and $RemotePath -eq '/') {
      # Upstream OneDrive API may expose Personal Vault in root listing and
      # fail recursive traversals before filters are applied. Root cleanup is
      # best-effort only, so skip it and rely on allowlist bisync filters to
      # prevent macOS metadata churn for reachable trees.
      Write-Warning "replica-bisync: [$ReplicaId] skipping remote macOS metadata cleanup at OneDrive root due to API invalidResourceId limitation"
      return $true
    }

    $cleanupArgs = @(
      'delete',
      $RemoteRef,
      '--rmdirs',
      '--retries', '1',
      '--low-level-retries', '1',
      '--timeout', '30s',
      '--contimeout', '10s',
      '--max-duration', '2m'
    )

    foreach ($pattern in $macOSMetadataRemoteFilterGlobs) {
      $cleanupArgs += @('--filter', "+ $pattern")
    }
    $cleanupArgs += @('--filter', '- **')

    if ($Provider -eq 'iCloud') {
      $cleanupArgs += @('--iclouddrive-service', $ICloudService)
    }

    if ($Provider -eq 'OneDrive') {
      $cleanupArgs += @('--disable', 'ListR', '--filter', '- Personal Vault', '--filter', '- Personal Vault/**', '--filter', '- /Personal Vault', '--filter', '- /Personal Vault/**')
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedFilterPath)) {
      $cleanupArgs += @('--filter-from', $ResolvedFilterPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeFilterPath)) {
      $cleanupArgs += @('--filter-from', $RuntimeFilterPath)
    }

    if (-not (Invoke-ReplicaRcloneCommand -Arguments $cleanupArgs -IsDryRun:$IsDryRun)) {
      Write-Warning "replica-bisync: [$ReplicaId] failed to clean remote macOS metadata artefacts"
      return $false
    }

    return $true
  }

  function Invoke-BidirectionalReplicaSync {
    param(
      [Parameter(Mandatory)]
      [string]$ReplicaId,
      [Parameter(Mandatory)]
      [string]$LocalDir,
      [Parameter(Mandatory)]
      [string]$RemoteRef,
      [Parameter(Mandatory)]
      [string]$StateMarker,
      [Parameter(Mandatory)]
      [string[]]$CommonArgs,
      [switch]$IsDryRun
    )

    function Invoke-BisyncWithLockRecovery {
      param(
        [Parameter(Mandatory)]
        [string[]]$BisyncArgs
      )

      if ($IsDryRun) {
        return (Invoke-ReplicaRcloneCommand -Arguments $BisyncArgs -IsDryRun:$IsDryRun)
      }

      $preflightRunningBisync = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
          $commandLine = [string]$_.CommandLine
          $commandLine.Contains(' bisync ') -and $commandLine.Contains($LocalDir) -and $commandLine.Contains($RemoteRef)
        } |
        Select-Object -First 1

      if ($null -ne $preflightRunningBisync) {
        Write-Warning "replica-bisync: [$ReplicaId] another bisync run is already active (PID $($preflightRunningBisync.ProcessId)); skipping this run without marking failure"
        return $true
      }

      $capturedOutput = @(& $rcloneCmd.Source @BisyncArgs 2>&1)
      foreach ($line in $capturedOutput) {
        Write-Output $line
      }

      if ($LASTEXITCODE -eq 0) {
        return $true
      }

      $combinedOutput = ($capturedOutput | ForEach-Object { [string]$_ }) -join "`n"
      if ($combinedOutput -notmatch 'prior lock file found:\s*(?<LockPath>[^\r\n]+\.lck)') {
        return $false
      }

      $lockPath = $Matches['LockPath'].Trim()
      $runningBisync = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
          $commandLine = [string]$_.CommandLine
          $commandLine.Contains(' bisync ') -and $commandLine.Contains($LocalDir) -and $commandLine.Contains($RemoteRef)
        } |
        Select-Object -First 1

      if ($null -ne $runningBisync) {
        Write-Warning "replica-bisync: [$ReplicaId] another bisync run is already active (PID $($runningBisync.ProcessId)); skipping this run without marking failure"
        return $true
      }

      if ([string]::IsNullOrWhiteSpace($lockPath) -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        Write-Warning "replica-bisync: [$ReplicaId] bisync lock contention detected but lock path is unavailable for stale-lock recovery"
        return $false
      }

      Write-Warning "replica-bisync: [$ReplicaId] clearing stale bisync lock at $lockPath and retrying once"
      $unlockArgs = @(
        'deletefile',
        $lockPath,
        '--log-level', 'ERROR',
        '--retries', '1',
        '--low-level-retries', '1',
        '--timeout', '30s',
        '--contimeout', '10s',
        '--max-duration', '30s'
      )
      if (-not (Invoke-ReplicaRcloneCommand -Arguments $unlockArgs)) {
        Write-Warning "replica-bisync: [$ReplicaId] failed to clear stale bisync lock at $lockPath"
        return $false
      }

      return (Invoke-ReplicaRcloneCommand -Arguments $BisyncArgs)
    }

    # --max-duration bounds full command runtime so stalled remotes fail
    # predictably instead of blocking daily fallback runs indefinitely.
    $bisyncArgs = @('--conflict-resolve', 'newer', '--max-lock', '2m', '--timeout', '60s', '--contimeout', '15s', '--max-duration', '2h', '--retries', '1', '--low-level-retries', '1', '--stats', '30s', '--stats-one-line', '--stats-log-level', 'NOTICE')
    $seeded = Test-Path -Path $StateMarker -PathType Leaf

    if ($seeded) {
      $seededArgs = @('bisync', $LocalDir, $RemoteRef, '--check-access') + $bisyncArgs + $CommonArgs
      if (Invoke-BisyncWithLockRecovery -BisyncArgs $seededArgs) {
        return $true
      }
      # Seed marker implies prior baseline state files should exist. Clear it
      # before recovery so subsequent invocations do not keep retrying the stale
      # seeded path after an interrupted/cache-pruned run.
      if (-not $IsDryRun -and (Test-Path -Path $StateMarker -PathType Leaf)) {
        Remove-Item -Path $StateMarker -Force
      }
      Write-Warning "replica-bisync: [$ReplicaId] seeded bisync check failed; cleared seed marker and retrying with recovery --resync"
      Write-Warning "replica-bisync: [$ReplicaId] recovery --resync is running; do not start another run until this command completes"
    }

    # Seed run: --resync WITHOUT --check-access because RCLONE_TEST access
    # marker files are created by --resync.
    $resyncArgs = @('bisync', $LocalDir, $RemoteRef, '--resync') + $bisyncArgs + $CommonArgs
    if (-not (Invoke-BisyncWithLockRecovery -BisyncArgs $resyncArgs)) {
      return $false
    }

    if (-not $IsDryRun) {
      New-Item -ItemType Directory -Path $replicaStateDir -Force | Out-Null
      New-Item -ItemType File -Path $StateMarker -Force | Out-Null
    }

    return $true
  }

  $failureCount = 0
  $replicaStateDir = Join-Path -Path $HOME -ChildPath ".config\nucleus\state\replica-bisync"

  foreach ($replica in $replicas) {
    $id = [string]$replica.id
    $direction = [string]$replica.direction
    if ([string]::IsNullOrWhiteSpace($direction)) {
      $direction = "bidirectional"
    }

    $localPath = [string]$replica.localPath
    $remoteName = [string]$replica.remoteName
    $remotePath = [string]$replica.remotePath
    if ([string]::IsNullOrWhiteSpace($remotePath)) {
      $remotePath = "/"
    }

    $provider = [string]$replica.provider
    $iCloudService = [string]$replica.iCloudService
    if ([string]::IsNullOrWhiteSpace($iCloudService)) {
      $iCloudService = "drive"
    }

    $localDir = Join-Path -Path $HOME -ChildPath $localPath
    $stateMarker = Join-Path -Path $replicaStateDir -ChildPath "$id.seeded"
    if (-not (Test-Path -Path $localDir -PathType Container)) {
      New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    }

    $remoteRef = "${remoteName}:${remotePath}"
    $resolvedFilterPath = Resolve-ReplicaFilterPath -Candidate ([string]$replica.filtersFile)
    $runtimeFilterPath = $null
    if ($null -ne $resolvedFilterPath -and -not (Test-Path -Path $resolvedFilterPath -PathType Leaf)) {
      Write-Error "replica-bisync: filters file '$resolvedFilterPath' not found for replica '$id'" -ErrorAction Continue
      $failureCount += 1
      continue
    }

    Clear-LocalMacOSMetadataArtifact -TargetDir $localDir -IsDryRun:$DryRun

    $commonArgs = @('--log-level', 'ERROR')
    if ($provider -eq "iCloud") {
      $commonArgs += @("--iclouddrive-service", $iCloudService)
    }
    if ($provider -eq "OneDrive") {
      # Microsoft currently exposes an inaccessible Personal Vault entry in some
      # root listings. Exclude rules alone are not reliable upstream, so for
      # root-level OneDrive replicas build an allowlist from accessible top-level
      # entries and sync only those.
      $commonArgs += @('--disable', 'ListR')
      if ($remotePath -eq '/') {
        $runtimeFilterPath = Get-OneDriveRootFilterFile -ReplicaId $id -LocalDir $localDir -RemoteRef $remoteRef -IsDryRun:$DryRun
        if ($null -ne $resolvedFilterPath) {
          $commonArgs += @('--filter-from', $resolvedFilterPath)
        }
        $commonArgs += @('--filter-from', $runtimeFilterPath)
      }
      elseif ($null -ne $resolvedFilterPath) {
        $commonArgs += @('--filter-from', $resolvedFilterPath)
      }
    }
    else {
      foreach ($pattern in $macOSMetadataRemoteFilterGlobs) {
        $commonArgs += @('--exclude', $pattern)
      }
      if ($null -ne $resolvedFilterPath) {
        $commonArgs += @('--filter-from', $resolvedFilterPath)
      }
    }

    # Remote metadata cleanup is best-effort: provider-specific API surfaces
    # may reject housekeeping traversals for protected paths. Continue bisync
    # and rely on warnings for operator visibility.
    if (-not (Clear-RemoteMacOSMetadataArtifact -ReplicaId $id -RemoteRef $remoteRef -RemotePath $remotePath -Provider $provider -ICloudService $iCloudService -ResolvedFilterPath $resolvedFilterPath -RuntimeFilterPath $runtimeFilterPath -IsDryRun:$DryRun)) {
      # no-op by design; warning already emitted by cleanup helper
    }

    switch ($direction) {
      "pull" {
        Write-Output "replica-bisync: [$id] pull $remoteRef -> $localDir"
        $ok = Invoke-ReplicaRcloneCommand -Arguments (@("sync", $remoteRef, $localDir) + $commonArgs) -IsDryRun:$DryRun
        if (-not $ok) {
          $failureCount += 1
        }
      }
      "push" {
        Write-Output "replica-bisync: [$id] push $localDir -> $remoteRef"
        $ok = Invoke-ReplicaRcloneCommand -Arguments (@("sync", $localDir, $remoteRef) + $commonArgs) -IsDryRun:$DryRun
        if (-not $ok) {
          $failureCount += 1
        }
      }
      "bidirectional" {
        Write-Output "replica-bisync: [$id] bisync $localDir <-> $remoteRef"
        $ok = Invoke-BidirectionalReplicaSync -ReplicaId $id -LocalDir $localDir -RemoteRef $remoteRef -StateMarker $stateMarker -CommonArgs $commonArgs -IsDryRun:$DryRun
        if (-not $ok) {
          Write-Error "replica-bisync: [$id] bisync failed" -ErrorAction Continue
          $failureCount += 1
        }
      }
      default {
        Write-Error "replica-bisync: unsupported direction '$direction' for replica '$id'" -ErrorAction Continue
        $failureCount += 1
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($runtimeFilterPath) -and (Test-Path -Path $runtimeFilterPath -PathType Leaf)) {
      Remove-Item -Path $runtimeFilterPath -Force
    }
  }

  if ($failureCount -gt 0) {
    throw "replica-bisync: completed with $failureCount failure(s)"
  }

  Write-Output "replica-bisync: completed successfully"
}
