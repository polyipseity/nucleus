#!/usr/bin/env pwsh
# Tests for the temporary nixpkgs override mechanism (nixpkgs-next).
# Run with: pwsh -NoProfile -File tests/scripts/nixpkgs-overrides-tests.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$overrides = Join-Path $repoRoot 'src/modules/packages/nixpkgs-overrides.nix'
$instruction = Join-Path $repoRoot '.agents/instructions/nixpkgs-overrides.instructions.md'
$agents = Join-Path $repoRoot 'AGENTS.md'
$flake = Join-Path $repoRoot 'src/flake.nix'

$passed = 0
$failed = 0

function Assert-Pass([string]$Name) {
  Write-Output "✓ $Name"
  $script:passed++
}

function Assert-Fail([string]$Name, [string]$Reason) {
  Write-Output "✗ ${Name}: $Reason"
  $script:failed++
}

if (Test-Path -LiteralPath $overrides) {
  Assert-Pass 'nixpkgs-overrides.nix exists'
} else {
  Assert-Fail 'nixpkgs-overrides.nix exists' "missing $overrides"
}

if (Test-Path -LiteralPath $overrides) {
  $content = Get-Content -LiteralPath $overrides -Raw
  $ok = ($content -match 'TEMPORARY nixpkgs overrides') -and
    ($content -match 'nixpkgs-next') -and
    ($content -match 'nixpkgs-overrides.instructions.md') -and
    ($content -match 'Build and validation') -and
    (($content -match 'never deleted when empty') -or ($content -match 'stay in the tree even when empty'))
  if ($ok) {
    Assert-Pass 'nixpkgs-overrides.nix keeps the mechanism/discovery/removal header'
  } else {
    Assert-Fail 'nixpkgs-overrides.nix header' 'missing required discovery or removal text'
  }

  $inOverlay = $false
  $markers = ''
  $entryFailed = $false
  $entryLine = ''
  foreach ($line in (Get-Content -LiteralPath $overrides)) {
    if ($line -match 'overlay = ') { $inOverlay = $true; $markers = ''; continue }
    if (-not $inOverlay) { continue }
    if ($line -match '^\s{2}\};\s*$') { break }
    if ($line -match '# TEMPORARY') { $markers += 'T' }
    if ($line -match '# REMOVE WHEN') { $markers += 'R' }
    if ($line -match '# WHY') { $markers += 'W' }
    if ($line -match '^\s+[A-Za-z0-9._+-]+\s*=') {
      if (-not (($markers -match 'T') -and ($markers -match 'R') -and ($markers -match 'W'))) {
        $entryFailed = $true
        $entryLine = $line
      }
      $markers = ''
    }
  }
  if (-not $entryFailed) {
    Assert-Pass 'every nixpkgs override entry has TEMPORARY, REMOVE WHEN, and WHY markers'
  } else {
    Assert-Fail 'override entry markers' "missing required markers near: $entryLine"
  }
}

if ((Test-Path -LiteralPath $flake) -and ((Get-Content -LiteralPath $flake -Raw) -match 'nixpkgs-overrides\.nix')) {
  Assert-Pass 'src/flake.nix imports the nixpkgs overrides module'
} else {
  Assert-Fail 'src/flake.nix imports nixpkgs-overrides.nix' 'not referenced from src/flake.nix'
}

$discoveryOk = (Test-Path -LiteralPath $instruction) -and
  (Test-Path -LiteralPath $agents) -and
  ((Get-Content -LiteralPath $agents -Raw) -match 'nixpkgs-overrides.instructions.md')
if ($discoveryOk) {
  Assert-Pass 'all discovery points reference nixpkgs-overrides'
} else {
  Assert-Fail 'discovery points' 'missing instruction or AGENTS bullet'
}

Write-Output ""
if ($failed -gt 0) {
  Write-Output "$passed passed, $failed failed"
  Write-Output "# nucleus-tally passed=$passed failed=$failed"
  exit 1
} else {
  Write-Output "$passed passed"
  Write-Output "# nucleus-tally passed=$passed failed=$failed"
  exit 0
}
