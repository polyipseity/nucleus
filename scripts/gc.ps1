<#
.SYNOPSIS
  Perform bounded garbage collection on Windows hosts.

.DESCRIPTION
  Windows-side counterpart to scripts/gc.sh.  Runs the following steps in
  order, each independently skippable:

    1. Remove stale decrypted wallpaper files under %USERPROFILE%\Pictures\wallpapers
       that no longer have a matching *.sops blob in src/assets/wallpapers/.
    2. Prune the Cargo source/registry/advisory-db cache via cargo-cache if the
       binary is present on PATH.  cargo-cache has no WinGet package; install it
       with `cargo install cargo-cache` after rustup sets up the toolchain.

  All file operations are scoped to the primary user profile.  The script is
  idempotent and safe to re-run.

.PARAMETER ModuleDir
  Path to the Windows helper module directory.
  Defaults to src\modules\windows relative to the repository root.

.PARAMETER RepoRoot
  Root of the repository.  Defaults to the parent of the scripts\ directory
  (i.e. $PSScriptRoot\..).

.PARAMETER SkipCargoCache
  Skip cargo-cache pruning even when cargo-cache is available on PATH.

.PARAMETER SkipWallpaperPrune
  Skip stale wallpaper file cleanup.

.EXAMPLE
  .\scripts\gc.ps1
  .\scripts\gc.ps1 -SkipCargoCache
  .\scripts\gc.ps1 -SkipWallpaperPrune -SkipCargoCache
#>
[CmdletBinding()]
param(
  [string]$ModuleDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\src\modules\windows"),
  [string]$RepoRoot  = (Join-Path -Path $PSScriptRoot -ChildPath ".."),
  [switch]$SkipCargoCache,
  [switch]$SkipWallpaperPrune
)

$ErrorActionPreference = "Stop"

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
$resolvedRepoRoot  = (Resolve-Path -Path $RepoRoot).Path

# Load only the modules required by this script.
. (Join-Path -Path $resolvedModuleDir -ChildPath "remove-nucleusstalewallpapers.ps1")

# ---- Step 1: stale wallpaper cleanup ----------------------------------------
# Keeps the decrypted gallery in sync with declarative source blobs.  Without
# this, removed or renamed wallpaper assets leave orphaned decrypted files on
# disk that continue to appear in the rotation.
if (-not $SkipWallpaperPrune) {
  $wallpaperAssetsDir = Join-Path -Path $resolvedRepoRoot -ChildPath "src\assets\wallpapers"
  $wallpaperOutputDir = Join-Path -Path $env:USERPROFILE   -ChildPath "Pictures\wallpapers"
  Remove-NucleusStaleWallpapers -AssetsDir $wallpaperAssetsDir -OutputDir $wallpaperOutputDir
}

# ---- Step 2: cargo cache prune ----------------------------------------------
# cargo-cache (github.com/matthiaskrgr/cargo-cache) reclaims space from
# %USERPROFILE%\.cargo\registry, %USERPROFILE%\.cargo\git, and advisory-db
# clones that accumulate during Rust development sessions.
#
# cargo-cache has no WinGet package; the binary becomes available after running
# `cargo install cargo-cache` once rustup (Rustlang.Rustup, system.dsc.yml)
# has set up the toolchain.  The presence probe below keeps this step a no-op
# until then so gc.ps1 is safe to run at any time.
if (-not $SkipCargoCache) {
  # Existence probe — command absent is expected and benign before cargo-cache
  # is manually installed.  The result is checked immediately below.
  $cargoCacheCmd = Get-Command -Name "cargo-cache" -ErrorAction SilentlyContinue
  if ($null -eq $cargoCacheCmd) {
    Write-Host "nucleus: cargo-cache unavailable; skipping cargo cache prune"
  } else {
    & $cargoCacheCmd.Source -r all
  }
}

Write-Host "nucleus: gc workflow completed"
