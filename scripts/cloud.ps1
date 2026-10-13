# cloud.ps1: nucleus cloud management CLI (Windows).
#
# PowerShell twin of scripts/cloud.sh. Dispatches to:
#   setup -> Invoke-CloudSetup   (verify/create rclone remotes, validate
#                                 credentials, optionally run nucleus apply)
#   reset -> Invoke-ReplicaReset (remove local replica data and rclone cache;
#                                 local-only, never touches remote)
#   sync  -> Invoke-ReplicaSync  (pull-only replica sync, remote -> local)
#
# Usage: .\scripts\cloud.ps1 <setup|reset|sync|status|restart> [options]
#
# Exit conditions: 0 on success; non-zero on any failure.

#Requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Action')]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'reset', 'sync', 'status', 'restart')]
  [string]$Action = 'setup',

  # setup options
  [switch]$Apply = $false,
  [switch]$NoApply = $false,

  # reset/sync options
  [switch]$DryRun = $false,
  [string]$ReplicaId = $(if ($env:NUCLEUS_REPLICA_ID) { $env:NUCLEUS_REPLICA_ID } else { '' }),
  [string]$RepoRoot = $(if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { '' }),

  [Alias("h")]
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
  @"
Nucleus cloud management CLI.

Usage: .\scripts\cloud.ps1 <setup|reset|sync> [options]

  setup    Verify/create rclone remotes, validate credentials, sync display
           names, and optionally run nucleus apply.
  reset    Remove local replica data and rclone cache (local-only).
  sync     Pull-only replica sync (remote -> local).
  status   Show up/down per mount from the platform mount state, with the
           last 20 lines of each mount's log.
  restart  Stop the rclone process for each mount; the scheduled task's loop
           remounts it within 30 seconds.

  setup options:
    -Apply|-NoApply   Run nucleus apply to converge cloud mount services
                      (default: -NoApply).

  reset/sync options:
    -DryRun           Print planned actions instead of executing them.
    -ReplicaId ID     Act only on the replica with the given id.
    -RepoRoot PATH    Repo checkout used to find src/users/.

  Common options:
    -Help             Show usage.
"@
}

if ($Help) {
  Show-Usage
  exit 0
}

# -NoApply is the default; -Apply wins when both are supplied.
$apply = $Apply -and -not $NoApply

# Pass -RepoRoot through to the underlying scripts via NUCLEUS_REPO_ROOT, the env
# var they consult for repo-root resolution.
if ($RepoRoot) {
  $env:NUCLEUS_REPO_ROOT = $RepoRoot
}

function Invoke-CloudStatus {
  <#
  .SYNOPSIS
    Reports up/down for every enabled cloud mount with its recent log tail.
  .DESCRIPTION
    The platform mount state is decided by whether the WinFsp mount point
    lists: rclone leaves the mount point as an empty real directory when the
    mount is down, so an empty listing is the down signal. The retained mount
    log is the runner's entire failure surface, mirroring the POSIX twin.
  .EXAMPLE
    .\scripts\cloud.ps1 status
  #>
  [CmdletBinding()]
  param()

  $modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
  Import-Module $modulePath -Force -DisableNameChecking
  . (Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Invoke-LogManagement.ps1')

  function Resolve-CloudStatusRepoRoot {
    $repoRoot = $env:NUCLEUS_REPO_ROOT
    if (-not $repoRoot) {
      # check-suppress:suppression_doc: probe -- may be invoked outside repo checkouts; resolution handled below.
      $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
      if ($candidate) { return $candidate }
      throw "NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 or run from the repo checkout."
    }
    if (-not (Test-Path -Path $repoRoot -PathType Container)) {
      throw "NUCLEUS_REPO_ROOT path '$repoRoot' does not exist or is not a directory."
    }
    return $repoRoot
  }

  $repoRoot = Resolve-CloudStatusRepoRoot
  $registry = & (Join-Path $repoRoot 'src\platforms\Windows\modules\Load-UserRegistry.ps1') -RepoRoot $repoRoot
  $primaryUser = $registry['primaryUser']
  if ($null -eq $primaryUser) {
    Write-NucleusError 'no primary user is declared in the user registry; cloud status cannot resolve mounts.'
    exit 1
  }

  $cloudDrives = $primaryUser['cloudDrives']
  $homeDirectory = [string]$primaryUser['homeDirectory']
  if ($null -eq $cloudDrives) {
    Write-NucleusInfo 'no cloudDrives configuration is declared for the primary user.'
    return
  }

  foreach ($mount in @($cloudDrives['mounts'] | Where-Object { $_ })) {
    $enabled = if ($null -ne $mount['enable']) { [bool]$mount['enable'] } else { $true }
    if (-not $enabled) { continue }

    $mountPoint = Join-Path $homeDirectory ([string]$mount['localPath'])
    $listing = @()
    if (Test-Path -LiteralPath $mountPoint -PathType Container) {
      # check-suppress:suppression_doc: an unreadable mount point counts as down rather than failing the whole report
      $listing = @(Get-ChildItem -LiteralPath $mountPoint -Force -ErrorAction SilentlyContinue)
    }
    $stateWord = if ($listing.Count -gt 0) { 'up' } else { 'down' }
    Write-NucleusInfo "$($mount['id']) $stateWord $mountPoint"

    $logFile = Join-Path (Get-NucleusLogDir) "cloud-drive-mount-$($mount['id'])\mount.log"
    Write-NucleusInfo "--- $($mount['id']) log (last 20 lines) ---"
    if (Test-Path -LiteralPath $logFile -PathType Leaf) {
      Get-Content -LiteralPath $logFile -Tail 20
    }
    else {
      Write-NucleusInfo "(no log yet at $logFile)"
    }
  }
}

function Invoke-CloudRestart {
  <#
  .SYNOPSIS
    Stops the rclone process for every enabled cloud mount.
  .DESCRIPTION
    Each mount's rclone process is matched by its mount point, the one
    command-line argument unique to the instance; the platform manager (task
    loop) remounts it within 30 seconds, so no start step is needed here.
  .EXAMPLE
    .\scripts\cloud.ps1 restart
  #>
  [CmdletBinding()]
  param()

  $modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
  Import-Module $modulePath -Force -DisableNameChecking

  function Resolve-CloudRestartRepoRoot {
    $repoRoot = $env:NUCLEUS_REPO_ROOT
    if (-not $repoRoot) {
      # check-suppress:suppression_doc: probe -- may be invoked outside repo checkouts; resolution handled below.
      $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
      if ($candidate) { return $candidate }
      throw "NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 or run from the repo checkout."
    }
    if (-not (Test-Path -Path $repoRoot -PathType Container)) {
      throw "NUCLEUS_REPO_ROOT path '$repoRoot' does not exist or is not a directory."
    }
    return $repoRoot
  }

  $repoRoot = Resolve-CloudRestartRepoRoot
  $registry = & (Join-Path $repoRoot 'src\platforms\Windows\modules\Load-UserRegistry.ps1') -RepoRoot $repoRoot
  $primaryUser = $registry['primaryUser']
  if ($null -eq $primaryUser) {
    Write-NucleusError 'no primary user is declared in the user registry; cloud restart cannot resolve mounts.'
    exit 1
  }

  $cloudDrives = $primaryUser['cloudDrives']
  $homeDirectory = [string]$primaryUser['homeDirectory']
  if ($null -eq $cloudDrives) {
    Write-NucleusInfo 'no cloudDrives configuration is declared for the primary user.'
    return
  }

  foreach ($mount in @($cloudDrives['mounts'] | Where-Object { $_ })) {
    $enabled = if ($null -ne $mount['enable']) { [bool]$mount['enable'] } else { $true }
    if (-not $enabled) { continue }

    $mountPoint = Join-Path $homeDirectory ([string]$mount['localPath'])
    # WHY .Contains and not -like: a mount point is a literal path; the wildcard
    #   interpretation in -like would need escaping for no benefit.
    # WHY both qualifiers: the POSIX twin matches the mount subcommand and the
    #   mount point, so an unrelated rclone job whose path merely extends the
    #   mount point (a replica sync) is never stopped.
    $processes = @(
      Get-CimInstance -ClassName Win32_Process -Filter "Name = 'rclone.exe'" |
        Where-Object {
          $_.CommandLine -and $_.CommandLine.Contains('rclone mount') -and $_.CommandLine.Contains($mountPoint)
        }
    )
    if ($processes.Count -eq 0) {
      Write-NucleusInfo "$($mount['id']) has no running rclone; the platform manager (task loop) starts it on its next beat"
      continue
    }
    foreach ($process in $processes) {
      Stop-Process -Id $process.ProcessId
      Write-NucleusInfo "$($mount['id']) rclone stopped (pid $($process.ProcessId)); the platform manager (task loop) remounts it within 30s"
    }
  }
}

switch ($Action) {
  'setup' {
    Invoke-CloudSetup -Apply $apply
  }
  'reset' {
    Invoke-ReplicaReset -DryRun $DryRun -ReplicaId $ReplicaId
  }
  'sync' {
    Invoke-ReplicaSync -DryRun $DryRun -ReplicaId $ReplicaId
  }
  'status' {
    Invoke-CloudStatus
  }
  'restart' {
    Invoke-CloudRestart
  }
}

function Invoke-CloudSetup {
  <#
  .SYNOPSIS
    Guides one-time cloud remote setup and validates cloud mount automation.

  .DESCRIPTION
    Verifies the required rclone remotes exist, creates each missing one with the
    correct provider type and repo-configured backend defaults, prompts for
    authentication, then validates credentials with rclone lsd and recreates any
    remote with stale auth tokens.

  .PARAMETER Apply
    Run nucleus apply to converge cloud mount services (default: $false).

  .NOTES
    Environment variables: NUCLEUS_APPLY.
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param(
    [bool]$Apply = $(if ($env:NUCLEUS_APPLY -eq 'true') { $true } else { $false })
  )

  $modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
  Import-Module $modulePath -Force -DisableNameChecking

  function Resolve-NucleusRoot {
    $repoRoot = $env:NUCLEUS_REPO_ROOT
    if (-not $repoRoot) {
      # check-suppress:suppression_doc: probe -- may be invoked outside repo checkouts; resolution handled below.
      $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
      if ($candidate) {
        return $candidate
      }
      throw "NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 or run from the repo checkout."
    }
    if (-not (Test-Path -Path $repoRoot -PathType Container)) {
      throw "NUCLEUS_REPO_ROOT path '$repoRoot' does not exist or is not a directory."
    }
    return $repoRoot
  }

  function Get-RcloneMissingRemote {
    param(
      [Parameter(Mandatory)]
      [string[]]$RequiredRemotes
    )

    # listremotes stderr is suppressed because missing/first-run configs may emit
    # expected setup hints; caller checks for null output and handles failure.
    # check-suppress:suppression_doc: probe -- rclone may not be configured yet; $LASTEXITCODE checked below.
    $listed = & rclone listremotes 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $null
    }

    $missing = @()
    foreach ($remote in $RequiredRemotes) {
      if (-not ($listed -contains "${remote}:")) {
        $missing += $remote
      }
    }

    return $missing
  }

  function Get-ProviderType {
    param([Parameter(Mandatory)][string]$RemoteName)
    switch ($RemoteName) {
      'GoogleDrive' { return 'drive' }
      'iCloud'      { return 'iclouddrive' }
      'OneDrive'    { return 'onedrive' }
      default       { return $null }
    }
  }

  function Resolve-ICloudServiceForRemote {
    <#
    .SYNOPSIS
      Resolves the configured iCloud service for a remote from the user registry.

    .DESCRIPTION
      Reads the assembled user registry from src/users/ and returns the single configured
      iCloud service (`drive` or `photos`) for the current user's matching remote. With
      no explicit entry, or entries that disagree, the remote config defaults to `drive`
      and mount commands override per entry with `--iclouddrive-service`.

    .PARAMETER RepoRoot
      Absolute path to the repository root.

    .PARAMETER RemoteName
      rclone remote name being configured.
    #>
    param(
      [Parameter(Mandatory)]
      [string]$RepoRoot,

      [Parameter(Mandatory)]
      [string]$RemoteName
    )

    $loadUserRegistryScript = Join-Path $RepoRoot 'src\platforms\Windows\modules\Load-UserRegistry.ps1'
    if (-not (Test-Path -Path $loadUserRegistryScript -PathType Leaf)) {
      return 'drive'
    }

    $userRegistry = & $loadUserRegistryScript -RepoRoot $RepoRoot
    $users = $userRegistry.users
    if (-not $users -or $users.Count -eq 0) {
      return 'drive'
    }

    $currentUsername = $env:USERNAME
    $userRecord = @($users | Where-Object { $_.name -eq $currentUsername }) | Select-Object -First 1
    if ($null -eq $userRecord) {
      return 'drive'
    }

    $userCloudDrives = $userRecord.cloudDrives
    if ($null -eq $userCloudDrives) {
      return 'drive'
    }

    $matchingServices = @(
      @($userCloudDrives.mounts) + @($userCloudDrives.replicas) |
        Where-Object {
          $_ -and $_.provider -eq 'iCloud' -and $_.remoteName -eq $RemoteName
        } |
        ForEach-Object {
          if ($_.iCloudService) { [string]$_.iCloudService } else { 'drive' }
        } |
        Select-Object -Unique
    )

    if ($matchingServices.Count -eq 1) {
      return $matchingServices[0]
    }

    if ($matchingServices.Count -gt 1) {
      Write-NucleusWarning "multiple iCloud services are configured for remote '$RemoteName'; defaulting remote setup to 'drive' and letting mount commands override per entry."
    }

    return 'drive'
  }

  function Get-ProviderCreateArgument {
    <#
    .SYNOPSIS
      Returns backend-specific arguments for `rclone config create`.

    .DESCRIPTION
      `rclone config create` takes defaults for unanswered options, so the iCloud
      backend needs `--all` to force the full question flow for Apple ID, password and
      2FA. The service choice is passed explicitly so rclone skips the drive-vs-photos
      question.

    .PARAMETER ProviderType
      The rclone backend type string.

    .PARAMETER RemoteName
      The rclone remote name being created.

    .PARAMETER RepoRoot
      Absolute path to the repository root.
    #>
    param(
      [Parameter(Mandatory)]
      [string]$ProviderType,

      [Parameter(Mandatory)]
      [string]$RemoteName,

      [Parameter(Mandatory)]
      [string]$RepoRoot
    )

    switch ($ProviderType) {
      'drive' { return @('acknowledge_abuse', 'true') }
      'iclouddrive' {
        $iCloudService = Resolve-ICloudServiceForRemote -RepoRoot $RepoRoot -RemoteName $RemoteName
        return @('service', $iCloudService, '--all')
      }
      default { return @() }
    }
  }

  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    throw 'cloud-setup: rclone not found on PATH. Run apply/bootstrap first, then retry.'
  }

  $repoRoot = Resolve-NucleusRoot

  $requiredRemotes = @('GoogleDrive', 'iCloud', 'OneDrive')
  $missingRemotes = Get-RcloneMissingRemote -RequiredRemotes $requiredRemotes
  if ($null -eq $missingRemotes) {
    throw "cloud-setup: failed to read rclone remotes. Run 'rclone config' manually and retry."
  }

  if ($missingRemotes.Count -gt 0) {
    # Inject the rclone config passphrase from the materialized secret so remote
    # creation inherits it and rclone encrypts the new config with it.
    # WHY: conditional, since the secret may be absent before Windows apply has
    # materialized it; rclone then uses an unencrypted config.
    $rclonePassFile = Join-Path $HOME 'AppData\Local\nucleus\secrets\rclone-config-pass'
    if (Test-Path -Path $rclonePassFile -PathType Leaf) {
      $Env:RCLONE_CONFIG_PASS = (Get-Content -Path $rclonePassFile -Raw).Trim()
    }
    Write-NucleusInfo "missing rclone remotes: $($missingRemotes -join ', ')"
    Write-NucleusInfo 'creating and authenticating each missing remote...'
    foreach ($remote in $missingRemotes) {
      $providerType = Get-ProviderType -RemoteName $remote
      if ($null -eq $providerType) {
        Write-NucleusError "unknown remote '$remote'; add it manually with 'rclone config'."
        continue
      }
      $providerCreateArguments = Get-ProviderCreateArgument -ProviderType $providerType -RemoteName $remote -RepoRoot $repoRoot
      Write-NucleusInfo "setting up remote '$remote' (provider: $providerType)..."
      & rclone config create $remote $providerType @providerCreateArguments
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning "remote '$remote' setup exited with code $LASTEXITCODE."
      }
    }

    $missingRemotes = Get-RcloneMissingRemote -RequiredRemotes $requiredRemotes
    if ($null -eq $missingRemotes) {
      throw 'cloud-setup: failed to re-read rclone remotes after setup.'
    }
  }

  if ($missingRemotes.Count -gt 0) {
    throw "cloud-setup: required remotes are still missing: $($missingRemotes -join ', '). Rerun after completing those remotes in rclone config."
  }

  Write-NucleusInfo 'required remotes are configured.'

  # Recreate remotes with stale auth so the user can refresh tokens without
  # deleting and rebuilding the config by hand.
  # check-suppress:suppression_doc: cloud providers rotate tokens; the user should not need to manually
  # delete remotes to recover from expired credentials.
  Write-NucleusInfo 'validating remote credentials with root-only listings...'
  $staleRemotes = [System.Collections.Generic.List[string]]::new()
  foreach ($remote in $requiredRemotes) {
    # Suppressed: expected failure when credentials are stale; LASTEXITCODE drives branching.
    & rclone lsd "$remote`:">$null 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-NucleusInfo "✓ $remote credentials valid"
    } else {
      Write-NucleusWarning "✗ $remote credentials stale or unreachable; will recreate..."
      $staleRemotes.Add($remote)
    }
  }

  if ($staleRemotes.Count -gt 0) {
    $rclonePassFile = Join-Path $HOME 'AppData\Local\nucleus\secrets\rclone-config-pass'
    if (Test-Path -Path $rclonePassFile -PathType Leaf) {
      $Env:RCLONE_CONFIG_PASS = (Get-Content -Path $rclonePassFile -Raw).Trim()
    }
    foreach ($remote in $staleRemotes) {
      Write-NucleusInfo "deleting and recreating remote '$remote'..."
      & rclone config delete $remote
      $providerType = Get-ProviderType -RemoteName $remote
      $providerCreateArguments = Get-ProviderCreateArgument -ProviderType $providerType -RemoteName $remote -RepoRoot $repoRoot
      & rclone config create $remote $providerType @providerCreateArguments
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning "remote '$remote' recreation exited with code $LASTEXITCODE."
      }
    }

    Write-NucleusInfo 're-validating credentials after recreation...'
    $validationFailed = $false
    foreach ($remote in $staleRemotes) {
      # Suppressed: expected failure when recreation did not resolve credentials; LASTEXITCODE drives branching.
      & rclone lsd "$remote`:">$null 2>&1
      if ($LASTEXITCODE -eq 0) {
        Write-NucleusInfo "✓ $remote credentials valid"
      } else {
        Write-NucleusWarning "✗ $remote credentials still invalid after recreation"
        $validationFailed = $true
      }
    }

    if ($validationFailed) {
      throw 'cloud-setup: credential validation failed after recreation; recheck in rclone config.'
    }
  }

  Write-NucleusInfo 'all credentials valid.'

  # Ensure acknowledge_abuse is set on GoogleDrive, without which rclone gets 403
  # on files shared with "anyone with the link".
  # check-suppress:suppression_doc: probe -- rclone may not be configured yet; exit code checked downstream.
  $gdListed = & rclone listremotes 2>$null
  if ($LASTEXITCODE -eq 0 -and ($gdListed -contains 'GoogleDrive:')) {
    $gdAckAlreadySet = $false
    try {
      # check-suppress:suppression_doc: probe -- rclone may not be configured yet; catch block handles failure.
      $gdDump = & rclone config dump 2>$null | Out-String | ConvertFrom-Json
      if ($gdDump.GoogleDrive.acknowledge_abuse -eq 'true') {
        $gdAckAlreadySet = $true
      }
    } catch {
      # config dump failed; proceed with update anyway
      Write-Debug "cloud-setup: rclone config dump failed: $_"
    }
    if (-not $gdAckAlreadySet) {
      & rclone config update GoogleDrive acknowledge_abuse true
      if ($LASTEXITCODE -eq 0) {
        Write-NucleusInfo 'acknowledge_abuse set for GoogleDrive'
      } else {
        Write-NucleusWarning "failed to set acknowledge_abuse for GoogleDrive (exit code $LASTEXITCODE)"
      }
    } else {
      Write-NucleusInfo 'acknowledge_abuse already set for GoogleDrive, skipping'
    }
  } else {
    Write-NucleusWarning 'GoogleDrive remote not found, skipping acknowledge_abuse configuration'
  }

  if ($Apply) {
    Write-NucleusInfo 'running nucleus apply to converge cloud mount services...'
    & nix --option warn-dirty false run "$repoRoot/src#apply"
    if ($LASTEXITCODE -ne 0) {
      throw "cloud-setup: apply failed with exit code $LASTEXITCODE"
    }
  }

  Write-NucleusInfo "setup complete"
}

function Invoke-ReplicaReset {
  <#
  .SYNOPSIS
    Reset local cloud replica sync state on Windows.

  .DESCRIPTION
    Thin wrapper around `Invoke-ReplicaReset` from
    `src/platforms/Windows/modules/system/Invoke-ReplicaReset.ps1`.

  .PARAMETER DryRun
    Print planned reset actions without modifying local state (default: $false).

  .PARAMETER ReplicaId
    Optional replica id filter (default: none; all replicas reset).

  .NOTES
    Environment variables: NUCLEUS_DRY_RUN, NUCLEUS_REPLICA_ID.
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param(
    [bool]$DryRun = $(if ($env:NUCLEUS_DRY_RUN -eq 'true') { $true } else { $false }),
    [string]$ReplicaId = $(if ($env:NUCLEUS_REPLICA_ID) { $env:NUCLEUS_REPLICA_ID } else { '' })
  )

  $fmtModulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
  Import-Module $fmtModulePath -Force -DisableNameChecking

  function Resolve-NucleusRepoRoot {
    $repoRoot = $env:NUCLEUS_REPO_ROOT
    if (-not $repoRoot) {
      # check-suppress:suppression_doc: probe -- path may not exist; $null check handles absence.
      $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
      if ($candidate -and (Test-Path "$candidate\src\flake.nix")) {
        return $candidate
      }
      throw "NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 or run from the repo checkout."
    }
    if (-not (Test-Path -Path $repoRoot -PathType Container)) {
      throw "NUCLEUS_REPO_ROOT path '$repoRoot' does not exist or is not a directory."
    }
    return $repoRoot
  }

  $repoRoot = Resolve-NucleusRepoRoot
  $modulePath = Join-Path -Path $repoRoot -ChildPath 'src\platforms\Windows\modules\system\Invoke-ReplicaReset.ps1'

  if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "replica-reset: module not found at '$modulePath'."
  }

  . $modulePath

  Invoke-ReplicaReset -RepoRoot $repoRoot -DryRun:$DryRun -ReplicaId $ReplicaId
}

function Invoke-ReplicaSync {
  <#
  .SYNOPSIS
    Synchronize cloud replicas on Windows using src/modules/users.json.

  .DESCRIPTION
    Thin wrapper around `Invoke-ReplicaSync` from
    `src/platforms/Windows/modules/system/Invoke-ReplicaSync.ps1`.

  .PARAMETER DryRun
    Print planned actions without executing rclone commands (default: $false).

  .PARAMETER ReplicaId
    Optional replica id filter; when provided only the matching replica runs (default: none; all replicas run).

  .NOTES
    Environment variables: NUCLEUS_DRY_RUN, NUCLEUS_REPLICA_ID.
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param(
    [bool]$DryRun = $(if ($env:NUCLEUS_DRY_RUN -eq 'true') { $true } else { $false }),
    [string]$ReplicaId = $(if ($env:NUCLEUS_REPLICA_ID) { $env:NUCLEUS_REPLICA_ID } else { '' })
  )

  $modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
  Import-Module $modulePath -Force -DisableNameChecking

  function Resolve-NucleusRepoRoot {
    $repoRoot = $env:NUCLEUS_REPO_ROOT
    if (-not $repoRoot) {
      # check-suppress:suppression_doc: probe -- may be invoked outside repo checkouts; resolution handled below.
      $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
      if ($candidate) {
        return $candidate
      }
      throw "NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 or run from the repo checkout."
    }
    if (-not (Test-Path -Path $repoRoot -PathType Container)) {
      throw "NUCLEUS_REPO_ROOT path '$repoRoot' does not exist or is not a directory."
    }
    return $repoRoot
  }

  $repoRoot = Resolve-NucleusRepoRoot
  $modulePath = Join-Path -Path $repoRoot -ChildPath 'src\platforms\Windows\modules\system\Invoke-ReplicaSync.ps1'

  if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "replica-sync: module not found at '$modulePath'."
  }

  . $modulePath

  Invoke-ReplicaSync -RepoRoot $repoRoot -DryRun:$DryRun -ReplicaId $ReplicaId
}
