<#
.SYNOPSIS
  Perform bounded garbage collection on Windows hosts.

.DESCRIPTION
  Windows-side counterpart to scripts/gc.sh.  Runs the following steps in
  order, each independently skippable:

    1. Remove stale decrypted wallpaper files under %USERPROFILE%\Pictures\wallpapers
       that no longer have a matching *.sops blob in src/assets/wallpapers/.
    2. Prune bun/cargo/rustc/uv caches and the nucleus repo-local .direnv
      environment. cargo-cache remains the authoritative cleanup path for the
      Cargo registry/git/advisory-db cache when present; rustc-specific temp
      state is cleared via rustup's tmp directory.
    3. Remove old Scoop app versions and installer caches via `scoop cleanup *`.
        Guarded by a Scoop presence check so the step is a no-op when Scoop is
        not yet installed (e.g. before the first apply.ps1 run).
     4. Remove locally installed Ollama models absent from the declarative manifest
        at src/modules/ai/models.json.  Uses Invoke-AISync -PruneOnly so no new
        model pulls are triggered — GC only reclaims space.  Guarded by an ollama
        presence check so the step is a no-op when Ollama is not installed.

  All file operations are scoped to the primary user profile.  The script is
  idempotent and safe to re-run.

.PARAMETER ModuleDir
  Path to the Windows helper module directory. Mandatory: caller must
  explicitly pass the module directory so they are aware of which modules
  will be loaded and executed.

.PARAMETER RepoRoot
  Root of the repository. Mandatory: caller must explicitly pass the repo root
  so they are aware of which repository's assets and manifests will be accessed
  and modified.

.PARAMETER SkipToolCachePrune
  Skip bun/cargo/rustc/uv and repo-local .direnv cache cleanup.

.PARAMETER SkipOllamaPrune
  Skip Ollama orphaned model removal even when ollama is installed.

.PARAMETER SkipScoopCleanup
  Skip Scoop cache and old-version cleanup even when Scoop is installed.

.PARAMETER SkipWallpaperPrune
  Skip stale wallpaper file cleanup.

.EXAMPLE
  .\scripts\gc.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -RepoRoot "C:\Users\admin\nucleus"
  .\scripts\gc.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -RepoRoot "C:\Users\admin\nucleus" -SkipToolCachePrune
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ModuleDir,
  [Parameter(Mandatory)]
  [string]$RepoRoot,
  [switch]$SkipToolCachePrune,
  [switch]$SkipOllamaPrune,
  [switch]$SkipScoopCleanup,
  [switch]$SkipWallpaperPrune
)

$ErrorActionPreference = "Stop"

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
$resolvedRepoRoot  = (Resolve-Path -Path $RepoRoot).Path

# Load only the modules required by this script.
. (Join-Path -Path $resolvedModuleDir -ChildPath "remove-stalewallpaper.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-AISync.ps1")

# ---- Step 1: stale wallpaper cleanup ----------------------------------------
# Keeps the decrypted gallery in sync with declarative source blobs.  Without
# this, removed or renamed wallpaper assets leave orphaned decrypted files on
# disk that continue to appear in the rotation.
if (-not $SkipWallpaperPrune) {
  $wallpaperAssetsDir = Join-Path -Path $resolvedRepoRoot -ChildPath "src\assets\wallpapers"
  $wallpaperOutputDir = Join-Path -Path $env:USERPROFILE   -ChildPath "Pictures\wallpapers"
  Remove-StaleWallpaper -AssetsDir $wallpaperAssetsDir -OutputDir $wallpaperOutputDir
}

# ---- Step 2: tool cache prune -----------------------------------------------
# bun/cargo/rustc/uv all accumulate user-scoped caches under the Windows user
# profile, regardless of whether the binary came from the system install path
# or a direnv-loaded shell. Clearing those shared cache locations reclaims
# space for both system and devShell use without touching project-managed
# dependencies. rustc has no standalone cache tree; its transient artifacts are
# cleaned via cargo-cache and rustup's tmp directory.
if (-not $SkipToolCachePrune) {
  function Clear-DirectoryContentsIfPresent {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path,

      [Parameter(Mandatory = $true)]
      [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
      return
    }

    try {
      Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Remove-Item -Recurse -Force -ErrorAction Stop
    }
    catch {
      Write-Warning "gc: failed to prune $Label at '$Path' — $($_.Exception.Message)"
    }
  }

  $bunCacheDir = Join-Path $HOME ".bun\install\cache"
  $cargoBinstallCacheDir = Join-Path $env:LOCALAPPDATA "cargo-binstall\cache"
  $rustupTmpDir = Join-Path $HOME ".rustup\tmp"
  $uvCacheDir = Join-Path $env:LOCALAPPDATA "uv\cache"
  $repoDirenvDir = Join-Path $resolvedRepoRoot ".direnv"

  Clear-DirectoryContentsIfPresent -Path $bunCacheDir -Label "bun install cache"
  Clear-DirectoryContentsIfPresent -Path $cargoBinstallCacheDir -Label "cargo-binstall cache"
  Clear-DirectoryContentsIfPresent -Path $rustupTmpDir -Label "rustup temporary cache"

  $cargoCacheCmd = Get-Command -Name "cargo-cache" -ErrorAction SilentlyContinue
  if ($null -eq $cargoCacheCmd) {
    Write-Output "nucleus: cargo-cache unavailable; skipping cargo cache prune"
  } else {
    & $cargoCacheCmd.Source -r all
  }

  # uv does not need to be installed to clear its cache directory; remove the
  # cached wheels and artifacts directly when the platform-default path exists.
  Clear-DirectoryContentsIfPresent -Path $uvCacheDir -Label "uv cache"

  if (Test-Path -LiteralPath $repoDirenvDir -PathType Container) {
    try {
      Remove-Item -LiteralPath $repoDirenvDir -Recurse -Force -ErrorAction Stop
    }
    catch {
      Write-Warning "gc: failed to remove repo-local direnv cache '$repoDirenvDir' — $($_.Exception.Message)"
    }
  }
}

# ---- Step 3: Scoop cache and old-version cleanup ----------------------------
# 'scoop cleanup *' removes all old app versions and installer caches that
# Scoop retains by default, reclaiming disk space after updates.
# Guarded by a shim presence check because Scoop may not be installed on
# minimal setups or before the first apply.ps1 run.
if (-not $SkipScoopCleanup) {
  $scoopShims = Join-Path $env:USERPROFILE "scoop\shims"
  $scoopCmd   = Join-Path $scoopShims "scoop.cmd"
  if (-not (Test-Path $scoopCmd)) {
    Write-Output "gc: scoop not installed; skipping scoop cleanup"
  } else {
    if ($env:PATH -notlike "*$scoopShims*") {
      $env:PATH = "$scoopShims;$env:PATH"
    }
    Write-Output "gc: running scoop cleanup..."
    scoop cleanup *
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "gc: scoop cleanup exited with code $LASTEXITCODE"
    }
  }
}

# ---- Step 4: Ollama orphaned model prune ------------------------------------
# Removes locally installed Ollama models that are absent from the declarative
# manifest at src/modules/ai/models.json.  Uses -PruneOnly so GC never
# triggers multi-GB model pulls — only space reclamation.  Guarded by an
# ollama presence check so this step is a no-op before Ollama is installed.
if (-not $SkipOllamaPrune) {
  $ollamaCmd = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaCmd) {
    Write-Output "gc: ollama not installed; skipping ollama model prune"
  } else {
    Invoke-AISync -PruneOnly -RepoRoot $resolvedRepoRoot
  }
}

Write-Output "nucleus: gc workflow completed"
