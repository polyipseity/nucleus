<#
.SYNOPSIS
  Validates PowerShell semantic naming manifest and forbidden legacy names.

.DESCRIPTION
  Reads scripts/pwsh-naming-manifest.json and verifies:
    1. Each requiredNames entry points to an existing file containing the function.
    2. Each forbiddenNames entry does not appear as a function definition in src/ or scripts/.

  PSSA plural-noun and approved-verb checks remain in scripts/check-pwsh.ps1.

.PARAMETER RepoRoot
  Repository root. Defaults to parent of scripts/.

.PARAMETER ManifestPath
  Path to pwsh-naming-manifest.json. Defaults to scripts/pwsh-naming-manifest.json under RepoRoot.

.NOTES
  Exit codes: 0 on success; 1 on failure.
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$ManifestPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $ManifestPath = Join-Path $PSScriptRoot 'pwsh-naming-manifest.json'
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
  Write-Error "check-pwsh-naming: manifest not found at $ManifestPath"
  exit 1
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$failed = $false

foreach ($property in $manifest.requiredNames.PSObject.Properties) {
  $functionName = $property.Name
  $relativePath = [string]$property.Value
  $filePath = Join-Path $RepoRoot $relativePath

  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    Write-Error "check-pwsh-naming: required file missing for $functionName : $relativePath"
    $failed = $true
    continue
  }

  $content = Get-Content -LiteralPath $filePath -Raw
  $pattern = "function\s+$([regex]::Escape($functionName))\s*\{"
  if ($content -notmatch $pattern) {
    Write-Error "check-pwsh-naming: $relativePath must define function $functionName"
    $failed = $true
  }
}

$searchRoots = @(
  (Join-Path $RepoRoot 'src')
  (Join-Path $RepoRoot 'scripts')
)

foreach ($forbiddenName in @($manifest.forbiddenNames)) {
  $escaped = [regex]::Escape([string]$forbiddenName)
  $pattern = "function\s+$escaped\s*\{"

  foreach ($root in $searchRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }

    $matchedPaths = Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File |
      Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } |
      ForEach-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw
        if ($text -match $pattern) {
          $_.FullName.Substring($RepoRoot.Length + 1)
        }
      }

    foreach ($matchPath in @($matchedPaths)) {
      Write-Error "check-pwsh-naming: forbidden function $forbiddenName still defined in $matchPath"
      $failed = $true
    }
  }
}

if ($failed) {
  Write-Error 'check-pwsh-naming: naming manifest validation failed.'
  exit 1
}

$requiredCount = @($manifest.requiredNames.PSObject.Properties).Length
$forbiddenCount = @($manifest.forbiddenNames).Length
Write-Output "check-pwsh-naming: manifest validation passed ($requiredCount required names, $forbiddenCount forbidden names)."
