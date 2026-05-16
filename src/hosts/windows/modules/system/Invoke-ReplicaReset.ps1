<#
.SYNOPSIS
  Reset local replica sync state for manual troubleshooting.

.DESCRIPTION
  Clears only local state for enabled replicas declared in src/modules/users.json:
    - Legacy marker files under %USERPROFILE%\.config\nucleus\state\replica-*\<id>.seeded
    - Local replica data under each replica localPath
    - Local rclone cache directories related to sync/bisync

  This function never modifies remote data.

.PARAMETER RepoRoot
  Absolute repository root path.

.PARAMETER DryRun
  Print planned reset actions without changing local state.

.PARAMETER ReplicaId
  Optional replica id filter; when provided only matching marker and local
  replica cleanup is applied. Cache reset remains global because old rclone
  cache files are not reliably attributable to one replica id.
#>
function Invoke-ReplicaReset {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [switch]$DryRun,
    [string]$ReplicaId
  )

  $ErrorActionPreference = "Stop"
  $isMacOSHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $usersJsonPath = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\users.json"
  if (-not (Test-Path -Path $usersJsonPath -PathType Leaf)) {
    throw "replica-reset: users registry not found at '$usersJsonPath'."
  }

  $usersConfig = Get-Content -Raw -Path $usersJsonPath | ConvertFrom-Json
  $username = [System.Environment]::UserName

  $userConfigProperty = $usersConfig.PSObject.Properties | Where-Object { $_.Name -eq $username } | Select-Object -First 1
  if ($null -eq $userConfigProperty) {
    Write-Output "replica-reset: no user entry for '$username' in users.json; skipping"
    return
  }

  $replicas = @($userConfigProperty.Value.cloudDrives.replicas | Where-Object {
      $_.enable -eq $true -and -not [string]::IsNullOrWhiteSpace($_.remoteName)
    })

  if ($replicas.Count -eq 0) {
    Write-Output "replica-reset: no enabled replicas for user '$username'"
    return
  }

  if (-not [string]::IsNullOrWhiteSpace($ReplicaId)) {
    $replicas = @($replicas | Where-Object { $_.id -eq $ReplicaId })
    if ($replicas.Count -eq 0) {
      Write-Output "replica-reset: replica id '$ReplicaId' not enabled for user '$username'"
      return
    }
  }

  $legacyReplicaStateDirs = @(
    (Join-Path -Path $HOME -ChildPath ".config\nucleus\state\replica-bisync"),
    (Join-Path -Path $HOME -ChildPath ".config\nucleus\state\replica-sync")
  )

  foreach ($replica in $replicas) {
    $id = [string]$replica.id
    $localPath = [string]$replica.localPath
    $provider = [string]$replica.provider
    $iCloudService = [string]$replica.iCloudService
    if ([string]::IsNullOrWhiteSpace($iCloudService)) {
      $iCloudService = 'drive'
    }

    $localRoot = Join-Path -Path $HOME -ChildPath $localPath
    foreach ($stateDir in $legacyReplicaStateDirs) {
      $stateMarker = Join-Path -Path $stateDir -ChildPath "$id.seeded"
      if (Test-Path -Path $stateMarker -PathType Leaf) {
        if ($DryRun) {
          Write-Output "replica-reset: [dry-run] Remove-Item -Path '$stateMarker' -Force"
        }
        else {
          Remove-Item -Path $stateMarker -Force
        }
      }
    }

    # macOS iCloud Drive replicas are represented as symlinks to CloudDocs.
    # Never recurse into the symlink target during reset; remove only link.
    if ($isMacOSHost -and $provider -eq 'iCloud' -and $iCloudService -eq 'drive') {
      if (Test-Path -Path $localRoot) {
        $localItem = Get-Item -Path $localRoot -Force -ErrorAction SilentlyContinue
        $isSymlink = $null -ne $localItem -and ($localItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isSymlink) {
          if ($DryRun) {
            Write-Output "replica-reset: [dry-run] Remove-Item -Path '$localRoot' -Force"
          }
          else {
            Remove-Item -Path $localRoot -Force
          }
        }
        else {
          Write-Warning "replica-reset: [$id] expected iCloud drive symlink at '$localRoot'; leaving non-symlink path untouched"
        }
      }

      continue
    }

    # For non-exception replicas, reset clears local replica data only.
    if (Test-Path -Path $localRoot) {
      if ($DryRun) {
        Write-Output "replica-reset: [dry-run] Remove-Item -Path '$localRoot' -Recurse -Force"
      }
      else {
        Remove-Item -Path $localRoot -Recurse -Force
      }
    }

  }

  # Global rclone cache reset: paths vary by runtime (native Windows,
  # MSYS/WSL-like shells), so clear common local cache roots.
  $cacheDirs = [System.Collections.Generic.List[string]]::new()

  if (-not [string]::IsNullOrWhiteSpace($HOME)) {
    foreach ($cacheSuffix in @(
        ".cache\rclone\bisync",
        ".cache\rclone\bisync-lock",
        ".cache\rclone\sync",
        ".cache\rclone\sync-lock"
      )) {
      $candidate = Join-Path -Path $HOME -ChildPath $cacheSuffix
      if (-not $cacheDirs.Contains($candidate)) {
        [void]$cacheDirs.Add($candidate)
      }
    }
  }

  foreach ($cacheBase in @($env:LOCALAPPDATA, $env:APPDATA) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
    foreach ($cacheSuffix in @(
        "rclone\bisync",
        "rclone\bisync-lock",
        "rclone\sync",
        "rclone\sync-lock"
      )) {
      $candidate = Join-Path -Path $cacheBase -ChildPath $cacheSuffix
      if (-not $cacheDirs.Contains($candidate)) {
        [void]$cacheDirs.Add($candidate)
      }
    }
  }

  foreach ($cacheDir in $cacheDirs) {
    if (-not (Test-Path -Path $cacheDir -PathType Container)) {
      continue
    }
    if ($DryRun) {
      Write-Output "replica-reset: [dry-run] Remove-Item -Path '$cacheDir' -Recurse -Force"
    }
    else {
      Remove-Item -Path $cacheDir -Recurse -Force
    }
  }

  Write-Output "replica-reset: completed successfully"
}
