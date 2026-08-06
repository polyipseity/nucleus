<#
.SYNOPSIS
  Load and validate the user registry from src/users/ domain JSON files.

.DESCRIPTION
  Assembles per-user configuration by deep-merging src/users/default/ with
  src/users/<username>/ domain files, then resolving platform-keyed fields for
  Windows.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository root.

.OUTPUTS
  Returns a hashtable with keys: 'users' (array of user objects) and
  'primaryUser' (the user with isPrimary=true, or $null if none).

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; 1 on failure
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

$Platform = 'windows'
$UsersRoot = Join-Path -Path $RepoRoot -ChildPath 'src\users'
$DefaultRoot = Join-Path -Path $UsersRoot -ChildPath 'default'
$PlatformKeys = @('linux', 'macos', 'nixos', 'windows')

function Test-PlatformMap {
  param([object]$Value)

  if ($null -eq $Value) {
    return $false
  }
  if ($Value -isnot [System.Collections.IDictionary] -and $Value -isnot [pscustomobject]) {
    return $false
  }

  $keys = @()
  if ($Value -is [System.Collections.IDictionary]) {
    $keys = @($Value.Keys)
  }
  else {
    $keys = @($Value.PSObject.Properties.Name)
  }

  if ($keys.Count -eq 0) {
    return $false
  }

  foreach ($key in $keys) {
    if ($PlatformKeys -notcontains [string]$key) {
      return $false
    }
  }

  return $true
}

function Resolve-PlatformValue {
  param([object]$Value)

  if (-not (Test-PlatformMap -Value $Value)) {
    return $Value
  }

  if ($Value -is [pscustomobject]) {
    $Value = ConvertTo-PlainObject -InputObject $Value
  }

  foreach ($key in @($Platform, 'linux', 'macos', 'nixos', 'windows')) {
    if ($Value.ContainsKey($key)) {
      return $Value[$key]
    }
  }

  return ($Value.Values | Select-Object -First 1)
}

function ConvertTo-PlainObject {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$InputObject
  )

  if ($null -eq $InputObject) {
    return $null
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    $hash = @{}
    foreach ($key in $InputObject.Keys) {
      $hash[$key] = ConvertTo-PlainObject -InputObject $InputObject[$key]
    }
    return $hash
  }

  if ($InputObject -is [pscustomobject]) {
    $hash = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
      $hash[$property.Name] = ConvertTo-PlainObject -InputObject $property.Value
    }
    return $hash
  }

  if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
    return @($InputObject | ForEach-Object { ConvertTo-PlainObject -InputObject $_ })
  }

  return $InputObject
}

function Read-DomainJson {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if (-not (Test-Path -Path $Path -PathType Leaf)) {
    return @{}
  }

  $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
  $plain = ConvertTo-PlainObject -InputObject $raw
  if ($plain.ContainsKey('$schema')) {
    $plain.Remove('$schema')
  }
  return $plain
}

function Merge-Hashtables {
  param(
    [hashtable]$Base,
    [hashtable]$Override
  )

  $merged = @{}
  foreach ($key in $Base.Keys) {
    $merged[$key] = $Base[$key]
  }
  foreach ($key in $Override.Keys) {
    if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
      $merged[$key] = Merge-Hashtables -Base $merged[$key] -Override $Override[$key]
    }
    else {
      $merged[$key] = $Override[$key]
    }
  }
  return $merged
}

function Read-MergedDomain {
  param(
    [Parameter(Mandatory)]
    [string]$Username,
    [Parameter(Mandatory)]
    [string]$FileName
  )

  $defaultPath = Join-Path -Path $DefaultRoot -ChildPath $FileName
  $userPath = Join-Path -Path $UsersRoot -ChildPath (Join-Path $Username $FileName)
  return Merge-Hashtables -Base (Read-DomainJson -Path $defaultPath) -Override (Read-DomainJson -Path $userPath)
}

function Resolve-CloudDriveItem {
  param([hashtable]$Item)

  $resolved = @{}
  foreach ($key in $Item.Keys) {
    $resolved[$key] = $Item[$key]
  }

  if ($resolved.ContainsKey('localPath')) {
    $resolved['localPath'] = Resolve-PlatformValue -Value $resolved['localPath']
  }
  if ($resolved.ContainsKey('enable')) {
    $resolved['enable'] = Resolve-PlatformValue -Value $resolved['enable']
  }
  if ($resolved.ContainsKey('fallbackTimer') -and $resolved['fallbackTimer'] -is [hashtable] -and $resolved['fallbackTimer'].ContainsKey('enable')) {
    $resolved['fallbackTimer']['enable'] = Resolve-PlatformValue -Value $resolved['fallbackTimer']['enable']
  }

  return $resolved
}

function Resolve-CloudDrives {
  param([hashtable]$CloudDrives)

  $mounts = @()
  foreach ($mount in @($CloudDrives['mounts'])) {
    if ($null -ne $mount) {
      $mounts += Resolve-CloudDriveItem -Item $mount
    }
  }

  $replicas = @()
  foreach ($replica in @($CloudDrives['replicas'])) {
    if ($null -ne $replica) {
      $replicas += Resolve-CloudDriveItem -Item $replica
    }
  }

  return @{
    mounts   = $mounts
    replicas = $replicas
  }
}

function Resolve-DevRepos {
  param([hashtable]$DevRepos)

  $repositories = @()
  foreach ($repo in @($DevRepos['repositories'])) {
    if ($null -eq $repo) {
      continue
    }
    $resolvedRepo = @{}
    foreach ($key in $repo.Keys) {
      $resolvedRepo[$key] = $repo[$key]
    }
    if ($resolvedRepo.ContainsKey('target')) {
      $resolvedRepo['target'] = Resolve-PlatformValue -Value $resolvedRepo['target']
    }
    $repositories += $resolvedRepo
  }

  return @{
    enable                = $DevRepos['enable']
    gitHubUsername        = $DevRepos['gitHubUsername']
    repositories          = $repositories
    submoduleDirectories  = @($DevRepos['submoduleDirectories'])
  }
}

function Assemble-UserRecord {
  param(
    [Parameter(Mandatory)]
    [string]$Username
  )

  $profile = Read-MergedDomain -Username $Username -FileName 'profile.json'
  $homeDirectory = $null
  if ($profile.ContainsKey('homeDirectory')) {
    $homeDirectory = Resolve-PlatformValue -Value $profile['homeDirectory']
  }

  $cloudDrives = Resolve-CloudDrives -CloudDrives (Read-MergedDomain -Username $Username -FileName 'cloud-drives.json')
  $customProvision = Read-MergedDomain -Username $Username -FileName 'custom-provision-symlinks.json'
  $devRepos = Resolve-DevRepos -DevRepos (Read-MergedDomain -Username $Username -FileName 'dev-repos.json')
  $envVars = Read-MergedDomain -Username $Username -FileName 'env-vars.json'
  $icloud = Read-MergedDomain -Username $Username -FileName 'icloud-exclusions.json'
  $jellyfin = Read-MergedDomain -Username $Username -FileName 'jellyfin.json'
  $passwordStore = Read-MergedDomain -Username $Username -FileName 'password-store.json'
  $services = Read-MergedDomain -Username $Username -FileName 'services.json'
  $vmGuest = Read-MergedDomain -Username $Username -FileName 'vm-guest.json'
  $windows = Read-MergedDomain -Username $Username -FileName 'windows.json'

  return @{
    name                    = $Username
    isPrimary               = [bool]($profile['isPrimary'])
    homeDirectory           = [string]$homeDirectory
    cloudDrives             = $cloudDrives
    customProvisionSymlinks = @($customProvision['customProvisionSymlinks'])
    devRepos                = $devRepos
    envVars                 = $envVars
    iCloudExclusions        = @{
      excludedDirNames = @($icloud['excludedDirNames'])
      managedRoots     = @($icloud['managedRoots'])
    }
    jellyfin                = @{
      accounts  = @($jellyfin['accounts'])
      libraries = @($jellyfin['libraries'])
    }
    passwordStore           = @{
      path = [string]$passwordStore['path']
    }
    services                = $services
    vmGuest                 = @{
      passwordSecretKey = [string]$vmGuest['passwordSecretKey']
      usernameSecretKey = [string]$vmGuest['usernameSecretKey']
    }
    dscConfigFiles          = @($windows['dscConfigFiles'])
    description             = [string]($windows['description'])
  }
}

if (-not (Test-Path -Path $UsersRoot -PathType Container)) {
  Write-Error "User registry root not found: $UsersRoot" -ErrorAction Stop
  exit 1
}

$userList = @()
foreach ($entry in Get-ChildItem -Path $UsersRoot -Directory) {
  $name = $entry.Name
  if ($name -eq 'default' -or $name -eq 'schemas') {
    continue
  }

  $record = Assemble-UserRecord -Username $name
  if ([string]::IsNullOrWhiteSpace($record.homeDirectory)) {
    Write-Error "User '$name' missing required 'homeDirectory'" -ErrorAction Stop
    exit 1
  }
  $userList += $record
}

if ($userList.Count -eq 0) {
  Write-Error 'User registry contains no users' -ErrorAction Stop
  exit 1
}

$primaryUser = @($userList | Where-Object { $_.isPrimary })

@{
  users       = $userList
  primaryUser = if ($primaryUser.Count -eq 1) { $primaryUser[0] } else { $null }
}
