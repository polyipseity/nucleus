<#
.SYNOPSIS
  Remove stale `result` and `result-*` symlinks left by `nix build`,
  `nix run ... -o result`, or `nixos-generators`.

.DESCRIPTION
  Only removes symlinks — real files or directories with these names are
  preserved (with a warning) since they cannot be `result` artifacts.

  Exit codes:
    0  on success (no stale artifacts, or all cleaned up)

.PARAMETER WhatIf
  Print actions without executing them (PowerShell-native dry-run).

.PARAMETER Verbose
  Show detailed output about each path examined.

.EXAMPLE
  .\scripts\cleanup-nix.ps1
  .\scripts\cleanup-nix.ps1 -WhatIf
#>

#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }

$WhatIf = $false
$Verbose = $false
for ($_i = 0; $_i -lt $args.Count; $_i++) {
  switch ($args[$_i]) {
    '-WhatIf'      { $WhatIf = $true }
    '-Verbose'     { $Verbose = $true }
    '-h' { Write-Output "Usage: cleanup-nix.ps1 [-WhatIf] [-Verbose]"; exit 0 }
    '--help' { Write-Output "Usage: cleanup-nix.ps1 [-WhatIf] [-Verbose]"; exit 0 }
    default {
      [Console]::Error.WriteLine("ERROR: unsupported argument '$($args[$_i])'")
      exit 1
    }
  }
}

$_found = $false

# Recursively scan for result and result-* symlinks without following symlinks.
# Manual directory walk avoids Get-ChildItem -Recurse which follows reparse points.
# Use an index cursor to avoid range-operator edge cases with single-element arrays.
$_dirIndex = 0
$_directories = @($RepoRoot)

while ($_dirIndex -lt $_directories.Count) {
  $_dir = $_directories[$_dirIndex]
  $_dirIndex++

  foreach ($_pattern in @('result', 'result-*')) {
    # check-suppress:suppression_doc: probe -- result symlinks may not exist; ForEach-Object handles absent results gracefully.
    Get-ChildItem -Path $_dir -Filter $_pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.LinkType -eq 'SymbolicLink') {
        $_target = $_.Target
        if ($WhatIf) {
          Write-Output "cleanup-nix: [dry-run] would remove stale Nix build symlink: $($_.FullName) -> $_target"
        } else {
          Remove-Item -LiteralPath $_.FullName -Force
          Write-Output "cleanup-nix: removed stale Nix build symlink: $($_.FullName) -> $_target"
        }
      } elseif ($_.PSIsContainer -or (-not $_.LinkType)) {
        if ($Verbose) {
          Write-Output "cleanup-nix: found non-symlink at $($_.FullName) — skipping (not a Nix build artifact)"
        }
      }
    }
  }

  # Enqueue subdirectories, skipping reparse points (symlinks/junctions)
  # to avoid following symlinks into Nix store or other large trees.
  # check-suppress:suppression_doc: -ErrorAction SilentlyContinue on Get-ChildItem to skip permission-denied directories without aborting traversal.
  Get-ChildItem -Path $_dir -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
    ForEach-Object { $_directories += $_.FullName }
}

if (-not $_found) {
  Write-Output "cleanup-nix: no stale Nix build artifacts found."
}
