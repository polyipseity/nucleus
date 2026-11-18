# completions-bash-probe.ps1 - bash probe helpers for completions-fresh (Windows).
#
# Function definitions only; no top-level side effects. Dot-source this library
# from a step action runspace or tests that need the helpers.

function ConvertTo-NucleusGitBashPath {
  param([Parameter(Mandatory)][string]$Path)

  # Git-bash (MSYS) rejects Windows backslash script paths in probes; normalize
  # separators and translate a drive letter to /x/... for portability.
  $normalized = $Path -replace '\\', '/'
  if ($normalized -match '^([A-Za-z]):(.*)$') {
    return '/' + $Matches[1].ToLowerInvariant() + $Matches[2]
  }
  return $normalized
}

function Get-NucleusBashVersionString {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$VersionOutput)

  # GNU bash prints e.g. "GNU bash, version 5.2.15(1)-release ..."; accept the
  # first x.y or x.y.z token after "version ".
  $match = [regex]::Match($VersionOutput, 'version\s+(?<ver>[0-9]+(?:\.[0-9]+)+)')
  if ($match.Success) {
    return $match.Groups['ver'].Value
  }
  return $null
}

function Test-NucleusBashVersionAtLeast {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$VersionOutput,
    [version]$Minimum = [version]'5.1'
  )

  $versionString = Get-NucleusBashVersionString -VersionOutput $VersionOutput
  if (-not $versionString) {
    return $false
  }

  try {
    $parsed = [version]$versionString
  } catch {
    return $false
  }

  # A parsed "5.2" compares as 5.2.0.0; normalize floor the same way.
  if ($parsed.Major -gt $Minimum.Major) { return $true }
  if ($parsed.Major -lt $Minimum.Major) { return $false }
  $parsedMinor = if ($parsed.Minor -ge 0) { $parsed.Minor } else { 0 }
  $minimumMinor = if ($Minimum.Minor -ge 0) { $Minimum.Minor } else { 0 }
  if ($parsedMinor -gt $minimumMinor) { return $true }
  if ($parsedMinor -lt $minimumMinor) { return $false }
  $parsedBuild = if ($parsed.Build -ge 0) { $parsed.Build } else { 0 }
  $minimumBuild = if ($Minimum.Build -ge 0) { $Minimum.Build } else { 0 }
  return $parsedBuild -ge $minimumBuild
}

function Get-NucleusBashVersionRequirementError {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$VersionOutput,
    [string]$BashPath = 'bash',
    [version]$Minimum = [version]'5.1'
  )

  if (Test-NucleusBashVersionAtLeast -VersionOutput $VersionOutput -Minimum $Minimum) {
    return $null
  }

  $found = Get-NucleusBashVersionString -VersionOutput $VersionOutput
  if (-not $found) {
    $found = '(unknown version)'
  }
  $minimumText = '{0}.{1}' -f $Minimum.Major, $(if ($Minimum.Minor -ge 0) { $Minimum.Minor } else { 0 })
  return "bash at '$BashPath' reports version $found; >= $minimumText is required for completion introspection/probes"
}
