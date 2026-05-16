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
  Run nucleus apply to converge cloud mount services.
  (default: setup/validate only; user can run nucleus apply later)

.EXAMPLE
  .\cloud-setup.ps1

.EXAMPLE
  .\cloud-setup.ps1 -Apply
#>
[CmdletBinding()]
param(
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Resolve-NucleusRoot {
  $configPath = Join-Path $HOME '.config\nucleus\repo-root'
  if (Test-Path -Path $configPath -PathType Leaf) {
    $configuredRoot = (Get-Content -Path $configPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($configuredRoot) -and (Test-Path -Path $configuredRoot -PathType Container)) {
      return $configuredRoot
    }
  }

  # git rev-parse stderr is suppressed because running outside a git checkout
  # is expected and benign here; the result is validated before use.
  $gitRoot = (& git -C (Get-Location).Path rev-parse --show-toplevel 2>$null | Out-String).Trim()
  if (-not [string]::IsNullOrWhiteSpace($gitRoot) -and (Test-Path -Path $gitRoot -PathType Container)) {
    return $gitRoot
  }

  return (Join-Path $HOME 'dev\nucleus')
}

function Get-RcloneMissingRemote {
  param(
    [Parameter(Mandatory)]
    [string[]]$RequiredRemotes
  )

  # listremotes stderr is suppressed because missing/first-run configs may emit
  # expected setup hints; caller checks for null output and handles failure.
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
    Reads src/hosts/windows/users.json and returns the single configured
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

  $registryPath = Join-Path $RepoRoot 'src\hosts\windows\users.json'
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
    Write-Warning "cloud-setup: multiple iCloud services are configured for remote '$RemoteName'; defaulting remote setup to 'drive' and letting mount commands override per entry."
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
    'iclouddrive' {
      $iCloudService = Resolve-ICloudServiceForRemote -RepoRoot $RepoRoot -RemoteName $RemoteName
      return @('service', $iCloudService, '--all')
    }
    default { return @() }
  }
}

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
  Write-Output "cloud-setup: missing rclone remotes: $($missingRemotes -join ', ')"
  Write-Output 'cloud-setup: creating and authenticating each missing remote...'
  foreach ($remote in $missingRemotes) {
    $providerType = Get-ProviderType -RemoteName $remote
    if ($null -eq $providerType) {
      Write-Error "cloud-setup: unknown remote '$remote'; add it manually with 'rclone config'."
      continue
    }
    $providerCreateArguments = Get-ProviderCreateArgument -ProviderType $providerType -RemoteName $remote -RepoRoot $repoRoot
    Write-Output "cloud-setup: setting up remote '$remote' (provider: $providerType)..."
    & rclone config create $remote $providerType @providerCreateArguments
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "cloud-setup: remote '$remote' setup exited with code $LASTEXITCODE."
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

Write-Output 'cloud-setup: required remotes are configured.'

# Validate credentials; recreate remotes with stale auth so the user can refresh
# tokens without manually deleting and rebuilding the config.
# WHY: cloud providers rotate tokens; the user should not need to manually
# delete remotes to recover from expired credentials.
Write-Output 'cloud-setup: validating remote credentials with root-only listings...'
$staleRemotes = [System.Collections.Generic.List[string]]::new()
foreach ($remote in $requiredRemotes) {
  # Suppressed: expected failure when credentials are stale; LASTEXITCODE drives branching.
  & rclone lsd "$remote`:">$null 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Output "cloud-setup: ✓ $remote credentials valid"
  } else {
    Write-Warning "cloud-setup: ✗ $remote credentials stale or unreachable; will recreate..."
    $staleRemotes.Add($remote)
  }
}

if ($staleRemotes.Count -gt 0) {
  $rclonePassFile = Join-Path $HOME '.config\nucleus\secrets\rclone-config-pass'
  if (Test-Path -Path $rclonePassFile -PathType Leaf) {
    $Env:RCLONE_CONFIG_PASS = (Get-Content -Path $rclonePassFile -Raw).Trim()
  }
  foreach ($remote in $staleRemotes) {
    Write-Output "cloud-setup: deleting and recreating remote '$remote'..."
    & rclone config delete $remote
    $providerType = Get-ProviderType -RemoteName $remote
    $providerCreateArguments = Get-ProviderCreateArgument -ProviderType $providerType -RemoteName $remote -RepoRoot $repoRoot
    & rclone config create $remote $providerType @providerCreateArguments
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "cloud-setup: remote '$remote' recreation exited with code $LASTEXITCODE."
    }
  }

  Write-Output 'cloud-setup: re-validating credentials after recreation...'
  $validationFailed = $false
  foreach ($remote in $staleRemotes) {
    # Suppressed: expected failure when recreation did not resolve credentials; LASTEXITCODE drives branching.
    & rclone lsd "$remote`:">$null 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-Output "cloud-setup: ✓ $remote credentials valid"
    } else {
      Write-Warning "cloud-setup: ✗ $remote credentials still invalid after recreation"
      $validationFailed = $true
    }
  }

  if ($validationFailed) {
    throw 'cloud-setup: credential validation failed after recreation; recheck in rclone config.'
  }
}

Write-Output 'cloud-setup: all credentials valid.'

if ($Apply) {
  Write-Output 'cloud-setup: running nucleus apply to converge cloud mount services...'
  & nix --option warn-dirty false run "$repoRoot/src#apply"
  if ($LASTEXITCODE -ne 0) {
    throw "cloud-setup: apply failed with exit code $LASTEXITCODE"
  }
}

Write-Output "$($PSStyle.Foreground.Green)cloud-setup: setup complete$($PSStyle.Reset)"
