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
  if (-not (Test-Path -Path $usersJsonPath -PathType Leaf)) {
    throw "replica-bisync: users registry not found at '$usersJsonPath'."
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
    if ($null -ne $resolvedFilterPath -and -not (Test-Path -Path $resolvedFilterPath -PathType Leaf)) {
      Write-Error "replica-bisync: filters file '$resolvedFilterPath' not found for replica '$id'" -ErrorAction Continue
      $failureCount += 1
      continue
    }

    $commonArgs = @("--log-level", "ERROR")
    if ($provider -eq "iCloud") {
      $commonArgs += @("--iclouddrive-service", $iCloudService)
    }
    if ($provider -eq "OneDrive") {
      # Microsoft exposes Personal Vault in the root listing even when the API
      # later rejects traversal. Exclude it proactively so post-apply bisync
      # stays reliable instead of failing every run on invalidResourceId.
      $commonArgs += @("--exclude", "Personal Vault", "--exclude", "Personal Vault/**")
    }
    if ($null -ne $resolvedFilterPath) {
      $commonArgs += @("--filter-from", $resolvedFilterPath)
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
        $ok = Invoke-ReplicaRcloneCommand -Arguments (@("bisync", $localDir, $remoteRef, "--check-access") + $commonArgs) -IsDryRun:$DryRun
        if (-not $ok) {
          # First run commonly needs --resync; retry once with explicit resync.
          $ok = Invoke-ReplicaRcloneCommand -Arguments (@("bisync", $localDir, $remoteRef, "--check-access", "--resync") + $commonArgs) -IsDryRun:$DryRun
          if (-not $ok) {
            $failureCount += 1
          } elseif (-not $DryRun) {
            New-Item -ItemType Directory -Path $replicaStateDir -Force | Out-Null
            New-Item -ItemType File -Path $stateMarker -Force | Out-Null
          }
        } elseif (-not $DryRun) {
          New-Item -ItemType Directory -Path $replicaStateDir -Force | Out-Null
          New-Item -ItemType File -Path $stateMarker -Force | Out-Null
        }
      }
      default {
        Write-Error "replica-bisync: unsupported direction '$direction' for replica '$id'" -ErrorAction Continue
        $failureCount += 1
      }
    }
  }

  if ($failureCount -gt 0) {
    throw "replica-bisync: completed with $failureCount failure(s)"
  }

  Write-Output "replica-bisync: completed successfully"
}
