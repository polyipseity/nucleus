<#
.SYNOPSIS
  Produce system-locked.dsc.yml by merging version pins from lockfile.json
  into system.dsc.yml (Windows).

.DESCRIPTION
  For each Microsoft.WinGet.Client/Package resource with source=winget, looks
  up the package ID in the lockfile winget section.  If a version is found,
  adds a `version` field under `settings`.  msstore packages are left
  unmodified.  The original system.dsc.yml is never modified.

.PARAMETER Help
  Show this help message.

.EXAMPLE
  .\generate-winget-locked-dsc.ps1

.NOTES
  Environment variable: NUCLEUS_REPO_ROOT (optional).
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$repoRoot = if ($env:NUCLEUS_REPO_ROOT) {
  $env:NUCLEUS_REPO_ROOT
} else {
  (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
}
$lockfileAbs = Join-Path -Path $repoRoot -ChildPath 'src\lockfiles\lockfile.json'
$dscIn = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\system.dsc.yml'
$dscOut = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\system-locked.dsc.yml'

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
foreach ($f in @($dscIn, $lockfileAbs)) {
  if (-not (Test-Path -Path $f)) {
    Write-Error "generate-winget-locked-dsc: $f not found"
    exit 1
  }
}

# ---------------------------------------------------------------------------
# Read lockfile winget section
# ---------------------------------------------------------------------------
$lockfile = Get-Content -Path $lockfileAbs -Raw | ConvertFrom-Json -AsHashtable
$lockedVersions = $lockfile.winget
if (-not $lockedVersions -or @($lockedVersions.Keys).Count -eq 0) {
  Write-Warning 'generate-winget-locked-dsc: lockfile winget section is empty; writing DSC without version pins'
}

# ---------------------------------------------------------------------------
# Read DSC and merge versions
# ---------------------------------------------------------------------------
Write-Output 'generate-winget-locked-dsc: generating locked DSC...'

$dscYaml = Get-Content -Path $dscIn -Raw
$dsc = $dscYaml | ConvertFrom-Yaml -AsHashtable

$pinCount = 0
foreach ($resource in $dsc.properties.resources) {
  if ($resource.resource -eq 'Microsoft.WinGet.Client/Package' -and $resource.settings.source -eq 'winget') {
    $id = $resource.settings.id
    if ($lockedVersions.ContainsKey($id) -and $lockedVersions[$id]) {
      $resource.settings.version = $lockedVersions[$id]
      $pinCount++
    }
  }
}

# Write output
$dsc | ConvertTo-Yaml -OutFile $dscOut

Write-Output "generate-winget-locked-dsc: wrote $dscOut ($pinCount version pins)"
