<#
.SYNOPSIS
  Guides one-time cloud remote setup and converges cloud mount automation.

.DESCRIPTION
  Performs a bounded cloud-drive setup workflow:
    1. verifies required rclone remotes exist (GoogleDrive, iCloud, OneDrive)
   2. creates each missing remote with the correct provider type and
     repo-configured backend defaults, then prompts for authentication
     (no manual menu navigation required)
    3. runs `nix run <repo>/src#apply` so cloud mount services converge

.PARAMETER SkipApply
  Validate/setup remotes only; do not run apply.

.EXAMPLE
  .\cloud-setup.ps1

.EXAMPLE
  .\cloud-setup.ps1 -SkipApply
#>
[CmdletBinding()]
param(
  [switch]$SkipApply
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
    backend requires interactive answers for Apple ID, password, and 2FA, so
    this function adds `--all` to force the full question flow.

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

if (-not $SkipApply) {
  Write-Output 'cloud-setup: running nucleus apply to converge cloud mount services...'
  & nix run "$repoRoot/src#apply"
  if ($LASTEXITCODE -ne 0) {
    throw "cloud-setup: apply failed with exit code $LASTEXITCODE"
  }
}

Write-Output "$($PSStyle.Foreground.Green)cloud-setup: setup complete$($PSStyle.Reset)"
