<#
.SYNOPSIS
  Perform bounded garbage collection on Windows hosts.

.DESCRIPTION
  Windows-side counterpart to scripts/gc.sh.  Runs the following steps in
  order, each independently skippable:

    1. Remove stale decrypted wallpaper files under %USERPROFILE%\Pictures\wallpapers
       that no longer have a matching *.sops blob in src/assets/wallpapers/.
     2. Prune the Cargo source/registry/advisory-db cache via cargo-cache if the
        binary is present on PATH.  cargo-cache is installed via cargo-binstall
        by Invoke-CargoBinstallSetup (apply.ps1).  The presence probe below keeps
        this step a no-op until cargo-binstall setup has run.
     3. Remove old Scoop app versions and installer caches via `scoop cleanup *`.
        Guarded by a Scoop presence check so the step is a no-op when Scoop is
        not yet installed (e.g. before the first apply.ps1 run).
     4. Remove locally installed Ollama models absent from the declarative manifest
        at src/modules/ai/models.json.  Uses Invoke-AiSync -PruneOnly so no new
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

.PARAMETER SkipCargoCache
  Skip cargo-cache pruning even when cargo-cache is available on PATH.

.PARAMETER SkipOllamaPrune
  Skip Ollama orphaned model removal even when ollama is installed.

.PARAMETER SkipScoopCleanup
  Skip Scoop cache and old-version cleanup even when Scoop is installed.

.PARAMETER SkipWallpaperPrune
  Skip stale wallpaper file cleanup.

.EXAMPLE
  .\scripts\gc.ps1 -ModuleDir "C:\Users\polyipseity\nucleus\src\modules\windows" -RepoRoot "C:\Users\polyipseity\nucleus"
  .\scripts\gc.ps1 -ModuleDir "C:\Users\polyipseity\nucleus\src\modules\windows" -RepoRoot "C:\Users\polyipseity\nucleus" -SkipCargoCache
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ModuleDir,
  [Parameter(Mandatory)]
  [string]$RepoRoot,
  [switch]$SkipCargoCache,
  [switch]$SkipOllamaPrune,
  [switch]$SkipScoopCleanup,
  [switch]$SkipWallpaperPrune
)

$ErrorActionPreference = "Stop"

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
$resolvedRepoRoot  = (Resolve-Path -Path $RepoRoot).Path

# Load only the modules required by this script.
. (Join-Path -Path $resolvedModuleDir -ChildPath "remove-nucleusstalewallpapers.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "ai-sync.ps1")

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
# cargo-cache is installed via cargo-binstall by Invoke-CargoBinstallSetup.
# The presence probe below keeps this step a no-op on machines where
# cargo-binstall setup has not yet run, so gc.ps1 is safe to call at any time.
if (-not $SkipCargoCache) {
  # Existence probe — command absent is expected and benign before cargo-cache
  # is manually installed.  The result is checked immediately below.
  $cargoCacheCmd = Get-Command -Name "cargo-cache" -ErrorAction SilentlyContinue
  if ($null -eq $cargoCacheCmd) {
    Write-Output "nucleus: cargo-cache unavailable; skipping cargo cache prune"
  } else {
    & $cargoCacheCmd.Source -r all
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
    Invoke-AiSync -PruneOnly -RepoRoot $resolvedRepoRoot
  }
}

Write-Output "nucleus: gc workflow completed"
