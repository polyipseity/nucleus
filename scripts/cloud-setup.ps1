<#
.SYNOPSIS
  Guides one-time cloud remote setup and validates cloud mount automation.

.DESCRIPTION
  Performs a bounded cloud-drive setup workflow:
    1. verifies required rclone remotes exist (GoogleDrive, iCloud, OneDrive)
    2. creates each missing remote with the correct provider type and
       repo-configured backend defaults, then prompts for authentication
       (no manual menu navigation required)
    3. validates each remote's credentials work (via rclone lsd); recreates any
       remote with stale auth tokens to avoid manual config deletion
    4. optionally runs `nix run <repo>/src#apply` if -Apply switch provided

.PARAMETER Apply
  Run nucleus apply to converge cloud mount services (default: $false).

.EXAMPLE
  .\cloud-setup.ps1

.EXAMPLE
  .\cloud-setup.ps1 -Apply

.NOTES
  Environment variables: NUCLEUS_APPLY.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [switch]$Apply = $(if ($env:NUCLEUS_APPLY -eq 'true') { $true } else { $false })
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
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
    Reads src/hosts/Windows/users.json and returns the single configured
    iCloud service (`drive` or `photos`) for the current user's matching remote.
    If there is no explicit entry, or multiple entries disagree, the function
    defaults the remote config to `drive` and lets mount commands override per
    entry with `--iclouddrive-service`.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .PARAMETER RemoteName
    rclone remote name being configured.

  .EXAMPLE
    Resolve-ICloudServiceForRemote -RepoRoot 'C:\dev\nucleus' -RemoteName 'iCloud'
  #>
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$RemoteName
  )

  $registryPath = Join-Path $RepoRoot 'src\hosts\Windows\users.json'
  if (-not (Test-Path -Path $registryPath -PathType Leaf)) {
    return 'drive'
  }

  $registry = Get-Content -Path $registryPath -Raw | ConvertFrom-Json -AsHashtable
  $users = $registry.users
  if (-not $users) {
    return 'drive'
  }

  $currentUsername = $env:USERNAME
  if (-not $users.ContainsKey($currentUsername)) {
    $primaryEntry = $users.GetEnumerator() | Where-Object { $_.Value.isPrimary -eq $true } | Select-Object -First 1
    if ($null -eq $primaryEntry) {
      return 'drive'
    }
    $currentUsername = $primaryEntry.Key
  }

  $userCloudDrives = $users[$currentUsername].cloudDrives
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
    `rclone config create` takes defaults for unanswered options. The iCloud
    backend requires interactive answers for Apple ID, password (the Apple
    account password), and 2FA, so this function adds `--all` to force the
    full question flow. The iCloud service choice is passed explicitly so
    rclone skips the drive-vs-photos question.

  .PARAMETER ProviderType
    The rclone backend type string.

  .PARAMETER RemoteName
    The rclone remote name being created.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .EXAMPLE
    Get-ProviderCreateArgument -ProviderType 'iclouddrive' -RemoteName 'iCloud' -RepoRoot 'C:\dev\nucleus'
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
  # Inject rclone config passphrase from materialized secret so remote creation
  # inherits it and rclone encrypts the new config with the managed passphrase.
  # WHY conditional: secret file may be absent before Windows apply has
  # materialized it; benign absence — rclone uses an unencrypted config.
  $rclonePassFile = Join-Path $HOME '.config\nucleus\secrets\rclone-config-pass'
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

# Validate credentials; recreate remotes with stale auth so the user can refresh
# tokens without manually deleting and rebuilding the config.
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
  $rclonePassFile = Join-Path $HOME '.config\nucleus\secrets\rclone-config-pass'
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

# Ensure acknowledge_abuse is set on GoogleDrive to prevent 403 errors on
# publicly-shared files. This is required for rclone to download files shared
# via Google Drive links with "anyone with the link" permissions.
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

Write-NucleusInfo "$($PSStyle.Foreground.Green)setup complete$($PSStyle.Reset)"
