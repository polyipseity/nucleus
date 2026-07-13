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

# Check result and result-* patterns at the repo root.
foreach ($_pattern in @('result', 'result-*')) {
  # WHY: probe — result symlinks may not exist; ForEach-Object handles absent results gracefully.
  $_paths = Get-ChildItem -Path $RepoRoot -Filter $_pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_item.LinkType -eq 'SymbolicLink') {
      $_target = $_item.Target
      if ($WhatIf) {
        Write-Output "cleanup-nix: [dry-run] would remove stale Nix build symlink: $($_item.FullName) -> $_target"
      } else {
        Remove-Item -LiteralPath $_item.FullName -Force
        Write-Output "cleanup-nix: removed stale Nix build symlink: $($_item.FullName) -> $_target"
      }
      $_found = $true
    } elseif ($_item.PSIsContainer -or (-not $_item.LinkType)) {
      if ($Verbose) {
        Write-Output "cleanup-nix: found non-symlink at $($_item.FullName) — skipping (not a Nix build artifact)"
      }
    }
  }
}

if (-not $_found) {
  Write-Output "cleanup-nix: no stale Nix build artifacts found."
}
