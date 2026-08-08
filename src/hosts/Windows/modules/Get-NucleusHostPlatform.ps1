<#
.SYNOPSIS
  Host and platform registry helpers for Windows (reads host-platform-registry.json).

.DESCRIPTION
  Mirrors POSIX helpers in src/scripts/lib/lib.sh: platform keys and flags live on
  the platform entity in the registry; hosts reference platform by name only.
#>

function Get-NucleusHostPlatformRegistryPath {
  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'NUCLEUS_REPO_ROOT not set'
  }
  return Join-Path -Path $repoRoot -ChildPath 'src\modules\host-platform-registry.json'
}

function Get-NucleusHostKey {
  <#
  .SYNOPSIS
    Returns the canonical host name for the current machine.
  #>
  if (-not [string]::IsNullOrWhiteSpace($env:NUCLEUS_HOST)) {
    return $env:NUCLEUS_HOST
  }
  return 'Windows'
}

function Get-NucleusPlatformForHost {
  <#
  .SYNOPSIS
    Reads platform key for a host from host-platform-registry.json.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [string]$HostName = (Get-NucleusHostKey)
  )

  $registryPath = Get-NucleusHostPlatformRegistryPath
  $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -AsHashtable
  if (-not $registry.hosts.ContainsKey($HostName)) {
    throw "Get-NucleusPlatformForHost: unknown host '$HostName'"
  }
  return $registry.hosts[$HostName].platform
}

function Test-NucleusPlatformFlag {
  <#
  .SYNOPSIS
    Tests whether a platform flag is set for a host (via registry platforms section).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [string]$HostName = (Get-NucleusHostKey),

    [Parameter(Mandatory)]
    [ValidateSet('darwin', 'posix', 'linux', 'win32')]
    [string]$Flag
  )

  $registryPath = Get-NucleusHostPlatformRegistryPath
  $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -AsHashtable
  $platform = Get-NucleusPlatformForHost -HostName $HostName
  if (-not $registry.platforms.ContainsKey($platform)) {
    throw "Test-NucleusPlatformFlag: unknown platform '$platform'"
  }
  $flags = $registry.platforms[$platform].flags
  if (-not $flags.ContainsKey($Flag)) {
    return $false
  }
  return [bool]$flags[$Flag]
}
