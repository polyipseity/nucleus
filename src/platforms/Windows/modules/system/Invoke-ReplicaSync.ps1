<#
.SYNOPSIS
  Synchronize enabled cloud replicas declared in src/users/.

.DESCRIPTION
  Windows counterpart to scripts/replica-sync.sh. Reads per-user replica
  definitions from src/users/ and performs pull-only replica
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

.EXAMPLE
  Invoke-ReplicaSync -RepoRoot 'C:\Users\admin\nucleus' -DryRun

.EXAMPLE
  Invoke-ReplicaSync -RepoRoot 'C:\Users\admin\nucleus' -ReplicaId 'photos'

.NOTES
  Environment variables:
    NUCLEUS_HOST  Host identifier used for host-matching logic.
    USERNAME      Current username for principal resolution.

  Exit codes:
    0 on success; 1 on error.
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
    Write-NucleusInfo -CommandName 'replica-sync' "running in dry-run mode (no changes will be made)"
  }

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  if ([string]::IsNullOrWhiteSpace($env:NUCLEUS_REPO_ROOT)) {
    $env:NUCLEUS_REPO_ROOT = $resolvedRepoRoot
  }
  . (Join-Path -Path $resolvedRepoRoot -ChildPath 'src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1')
  $loadUserRegistryScript = Join-Path -Path $resolvedRepoRoot -ChildPath "src\platforms\Windows\modules\Load-UserRegistry.ps1"
  if (-not (Test-Path -Path $loadUserRegistryScript -PathType Leaf)) {
    throw "replica-sync: user registry loader not found at '$loadUserRegistryScript'."
  }

  # check-suppress:suppression_doc: probe -- rclone may not be installed; $null check handles absence.
  $rcloneCmd = Get-Command -Name "rclone" -ErrorAction SilentlyContinue
  if ($null -eq $rcloneCmd) {
    Write-NucleusInfo -CommandName 'replica-sync' "rclone not found; skipping replica sync"
    return
  }

  $rclonePassPath = Join-Path -Path $HOME -ChildPath ".config\nucleus\secrets\rclone-config-pass"
  if (Test-Path -Path $rclonePassPath -PathType Leaf) {
    # check-suppress:suppression_doc: probe -- passphrase file may be unreadable; .Trim() handles empty result.
    $passphrase = (Get-Content -Path $rclonePassPath -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not [string]::IsNullOrWhiteSpace($passphrase)) {
      $env:RCLONE_CONFIG_PASS = $passphrase
    }
  }

  $usersRegistry = & $loadUserRegistryScript -RepoRoot $resolvedRepoRoot
  $isWindowsHost = (Get-NucleusHostKey) -eq 'Windows'
  # check-suppress:suppression_doc: probe -- icacls may not be available on non-Windows hosts; $null check handles absence.
  $icaclsCmd = Get-Command -Name "icacls" -ErrorAction SilentlyContinue
  # check-suppress:suppression_doc: probe -- attrib may not be available on non-Windows hosts; $null check handles absence.
  $attribCmd = Get-Command -Name "attrib" -ErrorAction SilentlyContinue
  $currentUserPrincipal = [System.Environment]::UserName
  try {
    $resolvedPrincipal = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (-not [string]::IsNullOrWhiteSpace($resolvedPrincipal)) {
      $currentUserPrincipal = $resolvedPrincipal
    }
  }
  catch {
    # Non-Windows PowerShell hosts (for example CI/parser checks on macOS)
    # do not implement WindowsIdentity. Keep a username fallback so dry-runs
    # and syntax validations remain cross-platform friendly.
    Write-Verbose "replica-sync: WindowsIdentity unavailable; using username fallback '$currentUserPrincipal'"
  }

  $username = [System.Environment]::UserName
  $userRecord = @($usersRegistry.users | Where-Object { $_.name -eq $username }) | Select-Object -First 1
  if ($null -eq $userRecord) {
    Write-NucleusInfo -CommandName 'replica-sync' "no user entry for '$username' in user registry; skipping"
    return
  }

  $replicas = @($userRecord.cloudDrives.replicas | Where-Object {
      $_.enable -eq $true
    })

  if ($replicas.Count -eq 0) {
    Write-NucleusInfo -CommandName 'replica-sync' "no enabled replicas for user '$username'"
    return
  }

  if (-not [string]::IsNullOrWhiteSpace($ReplicaId)) {
    $replicas = @($replicas | Where-Object { $_.id -eq $ReplicaId })
    if ($replicas.Count -eq 0) {
      Write-NucleusInfo -CommandName 'replica-sync' "replica id '$ReplicaId' not enabled for user '$username'"
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

  function Get-ReplicaGcConfig {
    param([Parameter(Mandatory)][string]$Provider)

    $replicaGc = $userRecord['cloudDrives']['replicaGc']
    if ($null -eq $replicaGc -or -not ($replicaGc -is [hashtable]) -or -not $replicaGc.ContainsKey($Provider)) {
      return [pscustomobject]@{
        Files = @()
        Directories = @()
        RemoteExcludes = @()
        BlockedRoots = @()
      }
    }

    $providerValue = $replicaGc[$Provider]
    if ($null -eq $providerValue) {
      return [pscustomobject]@{
        Files = @()
        Directories = @()
        RemoteExcludes = @()
        BlockedRoots = @()
      }
    }

    return [pscustomobject]@{
      Files = @(@($providerValue['files']) | ForEach-Object { [string]$_ })
      Directories = @(@($providerValue['dirs']) | ForEach-Object { [string]$_ })
      RemoteExcludes = @(@($providerValue['remoteExcludes']) | ForEach-Object { [string]$_ })
      BlockedRoots = @(@($providerValue['blockedRoots']) | ForEach-Object { [string]$_ })
    }
  }

  function Invoke-ReplicaRcloneCommand {
    param(
      [Parameter(Mandatory)]
      [string[]]$Arguments,
      [switch]$IsDryRun
    )

    if ($IsDryRun) {
      Write-NucleusDryRun -CommandName 'replica-sync' ("rclone " + ($Arguments -join ' '))
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
      [object]$Set,
      [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
      return
    }

    if ($null -ne $Set -and $Set.PSObject.Methods.Name -contains 'Add') {
      [void]$Set.Add($Value)  # check-suppress:suppression_doc: Add returns collection count, discarded
    }
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
      [string]$EntryName,
      [string[]]$BlockedRoots
    )

    if ([string]::IsNullOrWhiteSpace($EntryName)) {
      return $false
    }

    return $BlockedRoots -contains $EntryName.TrimEnd('/')
  }

  function Get-OneDriveRootFilterFile {
    param(
      [Parameter(Mandatory)]
      [string]$ReplicaId,
      [Parameter(Mandatory)]
      [string]$LocalDir,
      [Parameter(Mandatory)]
      [string]$RemoteRef,
      [string[]]$RemoteExcludes,
      [string[]]$BlockedRoots,
      [switch]$IsDryRun
    )

    $filterFile = [System.IO.Path]::GetTempFileName()
    $dirEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $fileEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    @($RemoteExcludes | ForEach-Object { "- $_" }) | Set-Content -Path $filterFile -Encoding utf8

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
    $remoteDirs = if ($IsDryRun) { @() } else { & $rcloneCmd.Source @remoteDirsArgs 2>$null }  # check-suppress:suppression_doc: probe -- remote may not exist; $LASTEXITCODE checked below
    if ($LASTEXITCODE -eq 0 -and $null -ne $remoteDirs) {
      foreach ($remoteDir in @($remoteDirs)) {
        $trimmedDir = ([string]$remoteDir).TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($trimmedDir)) {
          continue
        }
        if (Test-IsOneDriveInaccessibleRootEntry -EntryName $trimmedDir -BlockedRoots $BlockedRoots) {
          Write-NucleusWarning -CommandName 'replica-sync' "[$ReplicaId] skipping inaccessible OneDrive root entry '$trimmedDir'"
          continue
        }
        if (Test-RemoteTopLevelPathAccessible -RemoteRef $RemoteRef -EntryName $trimmedDir -IsDryRun:$IsDryRun) {
          Add-UniqueReplicaEntry -Set $dirEntries -Value $trimmedDir
        } else {
          Write-NucleusWarning -CommandName 'replica-sync' "[$ReplicaId] skipping inaccessible OneDrive root entry '$trimmedDir'"
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
    $remoteFiles = if ($IsDryRun) { @() } else { & $rcloneCmd.Source @remoteFilesArgs 2>$null }  # check-suppress:suppression_doc: probe -- remote may not exist; $LASTEXITCODE checked below
    if ($LASTEXITCODE -eq 0 -and $null -ne $remoteFiles) {
      foreach ($remoteFile in @($remoteFiles)) {
        if (Test-IsOneDriveInaccessibleRootEntry -EntryName ([string]$remoteFile) -BlockedRoots $BlockedRoots) {
          Write-NucleusWarning -CommandName 'replica-sync' "[$ReplicaId] skipping inaccessible OneDrive root entry '$remoteFile'"
          continue
        }
        Add-UniqueReplicaEntry -Set $fileEntries -Value ([string]$remoteFile)
      }
    }

    if (Test-Path -Path $LocalDir -PathType Container) {
      # check-suppress:suppression_doc: probe -- directory may be empty; foreach handles empty result.
      foreach ($localEntry in Get-ChildItem -Path $LocalDir -Force -ErrorAction SilentlyContinue) {
        if (Test-IsOneDriveInaccessibleRootEntry -EntryName $localEntry.Name -BlockedRoots $BlockedRoots) {
          Write-NucleusWarning -CommandName 'replica-sync' "[$ReplicaId] skipping inaccessible OneDrive root entry '$($localEntry.Name)'"
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
      [string[]]$FileGlobs,
      [string[]]$DirectoryNames,
      [switch]$IsDryRun
    )

    if (-not (Test-Path -Path $TargetDir -PathType Container)) {
      return
    }

    if ($IsDryRun) {
      Write-NucleusDryRun -CommandName 'replica-sync' "local metadata gc in '$TargetDir'"
      return
    }

    foreach ($pattern in $FileGlobs) {
      # check-suppress:suppression_doc: cleanup-after-failure; matched items may have been deleted between discovery and removal.
      Get-ChildItem -Path $TargetDir -Recurse -Force -File -Filter $pattern -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction Ignore
    }

    foreach ($directoryName in $DirectoryNames) {
      # check-suppress:suppression_doc: cleanup-after-failure; matched dirs may have been deleted between discovery and removal.
      Get-ChildItem -Path $TargetDir -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $directoryName } |
        Remove-Item -Recurse -Force -ErrorAction Ignore
    }
  }

  function Invoke-ReplicaTreeWritable {
    param(
      [Parameter(Mandatory)]
      [string]$TargetDir,
      [switch]$IsDryRun
    )

    if (-not (Test-Path -Path $TargetDir -PathType Container)) {
      return $true
    }

    if ($null -eq $icaclsCmd) {
      if ($isWindowsHost) {
        Write-NucleusWarning -CommandName 'replica-sync' "icacls unavailable; cannot unlock '$TargetDir' for sync"
        return $false
      }
      Write-NucleusInfo -CommandName 'replica-sync' "non-Windows host without icacls; skipping unlock for '$TargetDir'"
      return $true
    }

    if ($IsDryRun) {
      Write-NucleusDryRun -CommandName 'replica-sync' "unlock replica tree '$TargetDir' (remove deny + clear read-only attributes)"
      return $true
    }

    & $icaclsCmd.Source $TargetDir '/remove:d' $currentUserPrincipal '/T' '/C' > $null
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    if ($null -ne $attribCmd) {
      & $attribCmd.Source '-R' "$TargetDir\*" '/S' '/D' > $null
    }

    return $true
  }

  function Invoke-ReplicaTreeReadOnly {
    param(
      [Parameter(Mandatory)]
      [string]$TargetDir,
      [switch]$IsDryRun
    )

    if (-not (Test-Path -Path $TargetDir -PathType Container)) {
      return $true
    }

    if ($null -eq $icaclsCmd) {
      if ($isWindowsHost) {
        Write-NucleusWarning -CommandName 'replica-sync' "icacls unavailable; cannot lock '$TargetDir' as read-only"
        return $false
      }
      Write-NucleusInfo -CommandName 'replica-sync' "non-Windows host without icacls; skipping read-only lock for '$TargetDir'"
      return $true
    }

    if ($IsDryRun) {
      Write-NucleusDryRun -CommandName 'replica-sync' "lock replica tree '$TargetDir' (deny write/create/delete)"
      return $true
    }

    & $icaclsCmd.Source $TargetDir '/remove:d' $currentUserPrincipal '/T' '/C' > $null
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    & $icaclsCmd.Source $TargetDir '/deny' "${currentUserPrincipal}:(WD,AD,DC,D,WA,WEA)" '/T' '/C' > $null
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    if ($null -ne $attribCmd) {
      & $attribCmd.Source '+R' "$TargetDir\*" '/S' '/D' > $null
    }

    return $true
  }

  $failureCount = 0

  foreach ($replica in $replicas) {
    $id = [string]$replica.id
    $direction = [string]$replica.direction
    if ([string]::IsNullOrWhiteSpace($direction)) {
      $direction = 'pull'
    }
    if ($direction -ne 'pull') {
      Write-NucleusError -CommandName replica-sync "[$id] unsupported direction '$direction'; replicas are pull-only by policy" -ErrorAction Continue
      $failureCount += 1
      continue
    }

    $localPath = [string]$replica.localPath
    $remotePath = [string]$replica.remotePath
    if ([string]::IsNullOrWhiteSpace($remotePath)) {
      $remotePath = '/'
    }

    $readWrite = if ($null -ne $replica.readWrite) { [bool]$replica.readWrite } else { $false }
    $displayName = if ($null -ne $replica.name) { [string]$replica.name } else { $id }

    $provider = [string]$replica.provider
    $iCloudService = [string]$replica.iCloudService
    if ([string]::IsNullOrWhiteSpace($iCloudService)) {
      $iCloudService = 'drive'
    }

    $gcValues = Get-ReplicaGcConfig -Provider $provider

    $localDir = Join-Path -Path $HOME -ChildPath $localPath
    if (-not (Test-Path -Path $localDir -PathType Container)) {
      New-Item -ItemType Directory -Path $localDir -Force > $null
    }

    $unlocked = Invoke-ReplicaTreeWritable -TargetDir $localDir -IsDryRun:$DryRun
    if (-not $unlocked) {
      Write-NucleusError -CommandName replica-sync "[$id] failed to unlock replica tree '$localDir'" -ErrorAction Continue
      $failureCount += 1
      continue
    }

    $remoteRef = "${id}:${remotePath}"
    $resolvedFilterPath = Resolve-ReplicaFilterPath -Candidate ([string]$replica.filtersFile)
    $runtimeFilterPath = $null
    if ($null -ne $resolvedFilterPath -and -not (Test-Path -Path $resolvedFilterPath -PathType Leaf)) {
      Write-NucleusError -CommandName replica-sync "filters file '$resolvedFilterPath' not found for replica '$id'" -ErrorAction Continue
      if (-not $readWrite) {
        $lockedAfterFilterFailure = Invoke-ReplicaTreeReadOnly -TargetDir $localDir -IsDryRun:$DryRun
        if (-not $lockedAfterFilterFailure) {
          Write-NucleusError -CommandName replica-sync "[$displayName] failed to re-lock replica tree '$localDir' after filter validation failure" -ErrorAction Continue
          $failureCount += 1
        }
      }
      $failureCount += 1
      continue
    }

    Clear-LocalMacOSMetadataArtifact -TargetDir $localDir -FileGlobs $gcValues.Files -DirectoryNames $gcValues.Directories -IsDryRun:$DryRun

    $commonArgs = @('--log-level', 'ERROR')
    if ($provider -eq 'iCloud') {
      $commonArgs += @('--iclouddrive-service', $iCloudService)
    }
    if ($provider -eq 'OneDrive') {
      if ($remotePath -eq '/') {
        # Keep the defensive root probe/filter generation for Personal Vault,
        # but let the real sync use OneDrive's default recursive listing path.
        # For full-root pull replicas, forcing --disable ListR makes syncs
        # pathologically slow.
        $runtimeFilterPath = Get-OneDriveRootFilterFile -ReplicaId $id -LocalDir $localDir -RemoteRef $remoteRef -RemoteExcludes $gcValues.RemoteExcludes -BlockedRoots $gcValues.BlockedRoots -IsDryRun:$DryRun
        if ($null -ne $resolvedFilterPath) {
          $commonArgs += @('--filter-from', $resolvedFilterPath)
        }
        $commonArgs += @('--filter-from', $runtimeFilterPath)
      } elseif ($null -ne $resolvedFilterPath) {
        $commonArgs += @('--filter-from', $resolvedFilterPath)
      }
    } else {
      foreach ($pattern in $gcValues.RemoteExcludes) {
        $commonArgs += @('--exclude', $pattern)
      }
      if ($null -ne $resolvedFilterPath) {
        $commonArgs += @('--filter-from', $resolvedFilterPath)
      }
    }

    Write-NucleusInfo -CommandName 'replica-sync' "[$displayName] pull $remoteRef -> $localDir"
    $ok = Invoke-ReplicaRcloneCommand -Arguments (@('sync', $remoteRef, $localDir) + $commonArgs) -IsDryRun:$DryRun
    if (-not $ok) {
      $failureCount += 1
    }

    if (-not [string]::IsNullOrWhiteSpace($runtimeFilterPath) -and (Test-Path -Path $runtimeFilterPath -PathType Leaf)) {
      Remove-Item -Path $runtimeFilterPath -Force
    }

    if (-not $readWrite) {
      $locked = Invoke-ReplicaTreeReadOnly -TargetDir $localDir -IsDryRun:$DryRun
      if (-not $locked) {
        Write-NucleusError -CommandName replica-sync "[$displayName] failed to lock replica tree '$localDir'" -ErrorAction Continue
        $failureCount += 1
      }
    }
  }

  if ($failureCount -gt 0) {
    throw "replica-sync: completed with $failureCount failure(s)"
  }

  Write-NucleusInfo -CommandName 'replica-sync' "completed successfully"
}
