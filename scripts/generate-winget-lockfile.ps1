<#
.SYNOPSIS
  Query winget-pkgs manifests and populate the winget section in lockfile.json
  (Windows).

.DESCRIPTION
  Extracts WinGet package IDs from system.dsc.yml, discovers the latest
  version for each package from the microsoft/winget-pkgs GitHub repository
  (via the GitHub API), and writes the updated lockfile atomically.

  When run on a Windows machine with winget CLI available, falls back to
  `winget show <id>` for packages not found via the GitHub API.

.PARAMETER Help
  Show this help message.

.EXAMPLE
  .\generate-winget-lockfile.ps1

.NOTES
  Environment variable: NUCLEUS_REPO_ROOT (optional, overrides repo root detection).
  Environment variable: GITHUB_TOKEN (optional, strongly recommended to avoid rate limiting).
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
$lockfileRel = 'src\lockfiles\lockfile.json'
$lockfileAbs = Join-Path -Path $repoRoot -ChildPath $lockfileRel
$dscSystem = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\system.dsc.yml'

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if (-not (Test-Path -Path $dscSystem)) {
  Write-Error "generate-winget-lockfile: system.dsc.yml not found at $dscSystem"
  exit 1
}

if (-not (Test-Path -Path $lockfileAbs)) {
  Write-Error "generate-winget-lockfile: lockfile not found at $lockfileAbs"
  exit 1
}

# ---------------------------------------------------------------------------
# Read lockfile
# ---------------------------------------------------------------------------
$lockfile = Get-Content -Path $lockfileAbs -Raw | ConvertFrom-Json -AsHashtable
if (-not $lockfile.ContainsKey('winget')) {
  $lockfile.winget = @{}
}

# ---------------------------------------------------------------------------
# Extract winget package IDs from DSC YAML
# ---------------------------------------------------------------------------
Write-Output 'generate-winget-lockfile: extracting winget package IDs from DSC...'

$dscYaml = Get-Content -Path $dscSystem -Raw
$dsc = $dscYaml | ConvertFrom-Yaml -AsHashtable

$allIds = @()
foreach ($resource in $dsc.properties.resources) {
  if ($resource.resource -eq 'Microsoft.WinGet.Client/Package') {
    $allIds += @{ id = $resource.settings.id; source = $resource.settings.source }
  }
}

$wingetIds = $allIds | Where-Object { $_.source -eq 'winget' } | ForEach-Object { $_.id }

if ($wingetIds.Count -eq 0) {
  Write-Output 'generate-winget-lockfile: no winget packages found in DSC'
  exit 0
}

Write-Output "generate-winget-lockfile: found $($wingetIds.Count) winget packages"

# ---------------------------------------------------------------------------
# GitHub API headers
# ---------------------------------------------------------------------------
$githubHeaders = @{
  Accept = 'application/vnd.github.v3+json'
}
if ($env:GITHUB_TOKEN) {
  $githubHeaders.Authorization = "Bearer $env:GITHUB_TOKEN"
}

# ---------------------------------------------------------------------------
# Discover versions
# ---------------------------------------------------------------------------
$newVersions = @{}

foreach ($id in $wingetIds) {
  # Convert package ID to publisher/package path components
  $dotIndex = $id.LastIndexOf('.')
  $publisher = $id.Substring(0, $dotIndex)
  $package = $id.Substring($dotIndex + 1)
  $firstChar = $publisher.Substring(0, 1).ToLower()

  $currentVer = $null
  if ($lockfile.winget.ContainsKey($id)) {
    $currentVer = $lockfile.winget[$id]
  }

  Write-Host "  $id": -NoNewline

  try {
    $apiUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/$firstChar/$publisher/$package"
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $githubHeaders -Method Get
    $versions = $response | ForEach-Object { $_.name } | Sort-Object -Property @{ Expression = {[System.Version]::new($_) } } -ErrorAction SilentlyContinue
    if ($versions.Count -gt 0) {
      $latestVer = $versions[-1]
      Write-Host "found $latestVer" -NoNewline
      if ($latestVer -ne $currentVer) {
        if ($currentVer) {
          Write-Host " (was $currentVer)" -NoNewline
        } else {
          Write-Host ' (<unset>)' -NoNewline
        }
        $newVersions[$id] = $latestVer
      }
    }
    Write-Host ''
  } catch {
    # Try winget CLI fallback on Windows
    try {
      $wingetResult = & winget show --id $id --accept-source-agreements --disable-interactivity 2>$null
      if ($wingetResult -match '^Version\s+(.+)$') {
        $latestVer = $matches[1]
        Write-Host "found $latestVer (winget CLI)" -NoNewline
        if ($latestVer -ne $currentVer) {
          if ($currentVer) {
            Write-Host " (was $currentVer)" -NoNewline
          } else {
            Write-Host ' (<unset>)' -NoNewline
          }
          $newVersions[$id] = $latestVer
        }
      } else {
        Write-Host 'not found in winget-pkgs (skipping)' -NoNewline
      }
    } catch {
      Write-Host 'not found in winget-pkgs (skipping)' -NoNewline
    }
    Write-Host ''
  }
}

# ---------------------------------------------------------------------------
# Write updated lockfile
# ---------------------------------------------------------------------------
if ($newVersions.Count -gt 0) {
  Write-Output "`ngenerate-winget-lockfile: updating lockfile with $($newVersions.Count) version(s)..."

  foreach ($entry in $newVersions.GetEnumerator()) {
    $lockfile.winget[$entry.Key] = $entry.Value
  }

  # Write atomically
  $tmpFile = [System.IO.Path]::GetTempFileName()
  $lockfile | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -NoNewline
  Move-Item -Path $tmpFile -Destination $lockfileAbs -Force

  Write-Output "generate-winget-lockfile: lockfile updated ($lockfileRel)"
} else {
  Write-Output "`ngenerate-winget-lockfile: no updates needed"
}
