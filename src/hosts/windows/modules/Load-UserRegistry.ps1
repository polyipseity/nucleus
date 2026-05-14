<#
.SYNOPSIS
  Load and validate the Windows user registry from src/hosts/windows/users.json.

.DESCRIPTION
  Reads the declarative user registry and exposes functions for querying user
  configuration. The registry defines all users managed by this host
  configuration (primary and secondary) and their home directories. This
  mirrors the Nix users/default.nix module.

  The user registry is loaded once and cached during apply execution. All
  user-specific configuration (secrets, DSC, VSCode settings) must query this
  registry to determine which users to process.

.PARAMETER RegistryPath
  Absolute path to src/hosts/windows/users.json. Mandatory: callers must
  explicitly pass the path so they are aware of where host user configuration
  lives.

.OUTPUTS
  Returns a hashtable with keys: 'users' (array of user objects) and
  'primaryUser' (the user with isPrimary=true, or $null if none).

.EXAMPLE
  $registry = & "$ModuleDir\Load-UserRegistry.ps1" -RegistryPath "$PSScriptRoot\users.json"
  $adminUser = $registry.users | Where-Object { $_.name -eq 'admin' }
  Write-Host "Admin home: $($adminUser.homeDirectory)"

.EXAMPLE
  $registry = & "$ModuleDir\Load-UserRegistry.ps1" -RegistryPath "$PSScriptRoot\users.json"
  if ($registry.primaryUser) {
    Write-Host "Materializing secrets for: $($registry.primaryUser.name)"
  }
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$RegistryPath
)

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

# Load and validate the JSON registry file.
if (-not (Test-Path -Path $RegistryPath -PathType Leaf)) {
  Write-Error "User registry not found: $RegistryPath" -ErrorAction Stop
  exit 1
}

try {
  $rawRegistry = Get-Content -Path $RegistryPath -Raw | ConvertFrom-Json
} catch {
  Write-Error "Failed to parse user registry JSON: $_" -ErrorAction Stop
  exit 1
}

# Validate structure: must have 'users' object.
if (-not $rawRegistry.users -or $rawRegistry.users -isnot [PSCustomObject]) {
  Write-Error "User registry missing or invalid 'users' object" -ErrorAction Stop
  exit 1
}

# Convert users object to array of user records, adding the username as a property.
$userList = @()
foreach ($userName in $rawRegistry.users.PSObject.Properties.Name) {
  $userConfig = $rawRegistry.users.$userName
  if (-not $userConfig.homeDirectory) {
    Write-Error "User '$userName' missing required 'homeDirectory'" -ErrorAction Stop
    exit 1
  }
  $userList += @{
    name           = $userName
    dscConfigFiles = if ($userConfig.dscConfigFiles -is [System.Array]) {
      @($userConfig.dscConfigFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
      @()
    }
    cloudDrives    = ConvertTo-PlainObject -InputObject $userConfig.cloudDrives
    devRepos       = ConvertTo-PlainObject -InputObject $userConfig.devRepos
    homeDirectory  = $userConfig.homeDirectory
    isPrimary      = if ($userConfig.isPrimary) { $true } else { $false }
    obsidian       = ConvertTo-PlainObject -InputObject $userConfig.obsidian
    qtpass         = ConvertTo-PlainObject -InputObject $userConfig.qtpass
    description    = if ($userConfig.description) { $userConfig.description } else { "" }
  }
}

if ($userList.Count -eq 0) {
  Write-Error "User registry contains no users" -ErrorAction Stop
  exit 1
}

# Find the primary user (there should be exactly one, but the registry doesn't
# enforce this; activation logic will fail if zero or multiple are marked primary).
$primaryUser = $userList | Where-Object { $_.isPrimary }

# Return the loaded and validated registry.
@{
  users       = $userList
  primaryUser = if ($primaryUser.Count -eq 1) { $primaryUser } else { $null }
}
