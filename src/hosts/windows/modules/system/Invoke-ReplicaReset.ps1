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
    $stateMarker = Join-Path -Path $replicaStateDir -ChildPath "$id.seeded"

    if (Test-Path -Path $stateMarker -PathType Leaf) {
      if ($DryRun) {
        Write-Output "replica-reset: [dry-run] Remove-Item -Path '$stateMarker' -Force"
      }
      else {
        Remove-Item -Path $stateMarker -Force
      }
    }

    # rclone bisync check-access may create local RCLONE_TEST in replica roots.
    $localRoot = Join-Path -Path $HOME -ChildPath $localPath
    $localCheckMarker = Join-Path -Path $localRoot -ChildPath "RCLONE_TEST"
    if (Test-Path -Path $localCheckMarker -PathType Leaf) {
      if ($DryRun) {
        Write-Output "replica-reset: [dry-run] Remove-Item -Path '$localCheckMarker' -Force"
      }
      else {
        Remove-Item -Path $localCheckMarker -Force
      }
    }
  }

  # Global rclone bisync cache reset: paths vary by runtime (native Windows,
  # MSYS/WSL-like shells), so clear common local cache roots.
  $cacheDirs = @(
    (Join-Path -Path $HOME -ChildPath ".cache\rclone\bisync"),
    (Join-Path -Path $HOME -ChildPath ".cache\rclone\bisync-lock"),
    (Join-Path -Path $env:LOCALAPPDATA -ChildPath "rclone\bisync"),
    (Join-Path -Path $env:APPDATA -ChildPath "rclone\bisync")
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
