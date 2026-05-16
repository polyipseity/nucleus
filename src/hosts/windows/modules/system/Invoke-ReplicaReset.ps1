<#
.SYNOPSIS
  Reset local replica bisync state for manual troubleshooting.

.DESCRIPTION
  Clears only local state for enabled replicas declared in src/modules/users.json:
    - %USERPROFILE%\.config\nucleus\state\replica-bisync\<id>.seeded markers
    - Local RCLONE_TEST files under each replica localPath
    - Local rclone bisync cache directories

  This function never modifies remote data.

.PARAMETER RepoRoot
  Absolute repository root path.

.PARAMETER DryRun
  Print planned reset actions without changing local state.

.PARAMETER ReplicaId
  Optional replica id filter; when provided only matching marker and local
  RCLONE_TEST cleanup is applied. Cache reset remains global because rclone
  bisync cache files are not reliably attributable to one replica id.
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

  $replicaStateDir = Join-Path -Path $HOME -ChildPath ".config\nucleus\state\replica-bisync"

  foreach ($replica in $replicas) {
    $id = [string]$replica.id
    $localPath = [string]$replica.localPath
    $provider = [string]$replica.provider
    $iCloudService = [string]$replica.iCloudService
    if ([string]::IsNullOrWhiteSpace($iCloudService)) {
      $iCloudService = 'drive'
    }

    $localRoot = Join-Path -Path $HOME -ChildPath $localPath
    $stateMarker = Join-Path -Path $replicaStateDir -ChildPath "$id.seeded"

    if (Test-Path -Path $stateMarker -PathType Leaf) {
      if ($DryRun) {
        Write-Output "replica-reset: [dry-run] Remove-Item -Path '$stateMarker' -Force"
      }
      else {
        Remove-Item -Path $stateMarker -Force
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

    if ($DryRun) {
      Write-Output "replica-reset: [dry-run] New-Item -ItemType Directory -Path '$localRoot' -Force"
    }
    else {
      New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
    }
  }

  # Global rclone bisync cache reset: paths vary by runtime (native Windows,
  # MSYS/WSL-like shells), so clear common local cache roots.
  $cacheDirs = @(
    (Join-Path -Path $HOME -ChildPath ".cache\rclone\bisync"),
    (Join-Path -Path $HOME -ChildPath ".cache\rclone\bisync-lock"),
    (Join-Path -Path $env:LOCALAPPDATA -ChildPath "rclone\bisync"),
    (Join-Path -Path $env:LOCALAPPDATA -ChildPath "rclone\bisync-lock"),
    (Join-Path -Path $env:APPDATA -ChildPath "rclone\bisync"),
    (Join-Path -Path $env:APPDATA -ChildPath "rclone\bisync-lock")
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

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
