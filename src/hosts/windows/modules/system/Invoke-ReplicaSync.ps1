<#
.SYNOPSIS
  Synchronize enabled cloud replicas declared in src/modules/users.json.

.DESCRIPTION
  Windows counterpart to scripts/replica-sync.sh. Reads per-user replica
  definitions from src/modules/users.json and performs pull-only replica
  convergence (`rclone sync remote -> local`).

  Replica policy is strict:
    - pull is supported
    - push and bidirectional are rejected
  This preserves remote read-only behavior for replica automation.

.PARAMETER RepoRoot
  Repository root path.

.PARAMETER DryRun
  Prints planned rclone commands without executing them.

.PARAMETER ReplicaId
  Optional replica id filter; when provided only the matching replica runs.
#>

function Invoke-ReplicaSync {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [switch]$DryRun,
    [string]$ReplicaId
  )

  $ErrorActionPreference = "Stop"

  if ($DryRun) {
    Write-Output "replica-sync: running in dry-run mode (no changes will be made)"
  }

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $usersJsonPath = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\users.json"
  $cleanupConfigPath = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\configs\cloud\replica-cleanup.json"
  if (-not (Test-Path -Path $usersJsonPath -PathType Leaf)) {
    throw "replica-sync: users registry not found at '$usersJsonPath'."
  }
  if (-not (Test-Path -Path $cleanupConfigPath -PathType Leaf)) {
    throw "replica-sync: cleanup config not found at '$cleanupConfigPath'."
  }

  $rcloneCmd = Get-Command -Name "rclone" -ErrorAction SilentlyContinue
  if ($null -eq $rcloneCmd) {
    Write-Output "replica-sync: rclone not found; skipping replica sync"
    return
  }

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
    Write-Output "replica-sync: no user entry for '$username' in users.json; skipping"
    return
  }

  $replicas = @($userConfigProperty.Value.cloudDrives.replicas | Where-Object {
      $_.enable -eq $true -and -not [string]::IsNullOrWhiteSpace($_.remoteName)
    })

  if ($replicas.Count -eq 0) {
    Write-Output "replica-sync: no enabled replicas for user '$username'"
    return
  }

  if (-not [string]::IsNullOrWhiteSpace($ReplicaId)) {
    $replicas = @($replicas | Where-Object { $_.id -eq $ReplicaId })
    if ($replicas.Count -eq 0) {
      Write-Output "replica-sync: replica id '$ReplicaId' not enabled for user '$username'"
      return
    }
  }

  function Resolve-ReplicaFilterPath {
    param([string]$Candidate)

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
      Write-Output ("replica-sync: [dry-run] rclone " + ($Arguments -join ' '))
      return $true
    }

    & $rcloneCmd.Source @Arguments
    return ($LASTEXITCODE -eq 0)
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
    param([string]$EntryName)

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
          Write-Warning "replica-sync: [$ReplicaId] skipping inaccessible OneDrive root entry '$trimmedDir'"
          continue
        }
        if (Test-RemoteTopLevelPathAccessible -RemoteRef $RemoteRef -EntryName $trimmedDir -IsDryRun:$IsDryRun) {
          Add-UniqueReplicaEntry -Set $dirEntries -Value $trimmedDir
        } else {
          Write-Warning "replica-sync: [$ReplicaId] skipping inaccessible OneDrive root entry '$trimmedDir'"
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
          Write-Warning "replica-sync: [$ReplicaId] skipping inaccessible OneDrive root entry '$remoteFile'"
          continue
        }
        Add-UniqueReplicaEntry -Set $fileEntries -Value ([string]$remoteFile)
      }
    }

    if (Test-Path -Path $LocalDir -PathType Container) {
      foreach ($localEntry in Get-ChildItem -Path $LocalDir -Force -ErrorAction SilentlyContinue) {
        if (Test-IsOneDriveInaccessibleRootEntry -EntryName $localEntry.Name) {
          Write-Warning "replica-sync: [$ReplicaId] skipping inaccessible OneDrive root entry '$($localEntry.Name)'"
          continue
        }
        if ($localEntry.PSIsContainer) {
          Add-UniqueReplicaEntry -Set $dirEntries -Value $localEntry.Name
        } else {
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
      Write-Output "replica-sync: [dry-run] local metadata cleanup in '$TargetDir'"
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

  $failureCount = 0

  foreach ($replica in $replicas) {
    $id = [string]$replica.id
    $direction = [string]$replica.direction
    if ([string]::IsNullOrWhiteSpace($direction)) {
      $direction = 'pull'
    }
    if ($direction -ne 'pull') {
      Write-Error "replica-sync: [$id] unsupported direction '$direction'; replicas are pull-only by policy" -ErrorAction Continue
      $failureCount += 1
      continue
    }

    $localPath = [string]$replica.localPath
    $remoteName = [string]$replica.remoteName
    $remotePath = [string]$replica.remotePath
    if ([string]::IsNullOrWhiteSpace($remotePath)) {
      $remotePath = '/'
    }

    $provider = [string]$replica.provider
    $iCloudService = [string]$replica.iCloudService
    if ([string]::IsNullOrWhiteSpace($iCloudService)) {
      $iCloudService = 'drive'
    }

    $localDir = Join-Path -Path $HOME -ChildPath $localPath
    if (-not (Test-Path -Path $localDir -PathType Container)) {
      New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    }

    $remoteRef = "${remoteName}:${remotePath}"
    $resolvedFilterPath = Resolve-ReplicaFilterPath -Candidate ([string]$replica.filtersFile)
    $runtimeFilterPath = $null
    if ($null -ne $resolvedFilterPath -and -not (Test-Path -Path $resolvedFilterPath -PathType Leaf)) {
      Write-Error "replica-sync: filters file '$resolvedFilterPath' not found for replica '$id'" -ErrorAction Continue
      $failureCount += 1
      continue
    }

    Clear-LocalMacOSMetadataArtifact -TargetDir $localDir -IsDryRun:$DryRun

    $commonArgs = @('--log-level', 'ERROR')
    if ($provider -eq 'iCloud') {
      $commonArgs += @('--iclouddrive-service', $iCloudService)
    }
    if ($provider -eq 'OneDrive') {
      $commonArgs += @('--disable', 'ListR')
      if ($remotePath -eq '/') {
        $runtimeFilterPath = Get-OneDriveRootFilterFile -ReplicaId $id -LocalDir $localDir -RemoteRef $remoteRef -IsDryRun:$DryRun
        if ($null -ne $resolvedFilterPath) {
          $commonArgs += @('--filter-from', $resolvedFilterPath)
        }
        $commonArgs += @('--filter-from', $runtimeFilterPath)
      } elseif ($null -ne $resolvedFilterPath) {
        $commonArgs += @('--filter-from', $resolvedFilterPath)
      }
    } else {
      foreach ($pattern in $macOSMetadataRemoteFilterGlobs) {
        $commonArgs += @('--exclude', $pattern)
      }
      if ($null -ne $resolvedFilterPath) {
        $commonArgs += @('--filter-from', $resolvedFilterPath)
      }
    }

    Write-Output "replica-sync: [$id] pull $remoteRef -> $localDir"
    $ok = Invoke-ReplicaRcloneCommand -Arguments (@('sync', $remoteRef, $localDir) + $commonArgs) -IsDryRun:$DryRun
    if (-not $ok) {
      $failureCount += 1
    }

    if (-not [string]::IsNullOrWhiteSpace($runtimeFilterPath) -and (Test-Path -Path $runtimeFilterPath -PathType Leaf)) {
      Remove-Item -Path $runtimeFilterPath -Force
    }
  }

  if ($failureCount -gt 0) {
    throw "replica-sync: completed with $failureCount failure(s)"
  }

  Write-Output "replica-sync: completed successfully"
}
