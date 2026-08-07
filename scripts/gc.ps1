<#
.SYNOPSIS
  Perform bounded garbage collection on Windows hosts.

.DESCRIPTION
  Windows-side counterpart to scripts/gc.sh.  Runs the following steps in
  order, each independently skippable:

    1. Remove stale decrypted wallpaper files under %USERPROFILE%\Pictures\wallpapers
       that no longer have a matching overlay *.sops blob under src/users/*/wallpapers/.
    2. GC bun/cargo/rustc/uv caches and the nucleus repo-local .direnv
       environment. cargo-cache remains the authoritative gc path for the
       Cargo registry/git/advisory-db cache when present; rustc-specific temp
       state is cleared via rustup's tmp directory.
    3. Remove stale .git sample hooks and description files from ~/dev that
       were created before init.templateDir was configured.  Guarded by the
       NoGitTemplateGc switch.
    4. Remove stale .git cache/state files (gitk.cache, gc.log, stale lock/state
       files, deprecated branches/remotes/ dirs, refs/original/) and run
       `git gc --auto` in repos under ~/dev.  Active operation detection
       prevents state file removal during in-progress merges/rebase/bisects.
       Guarded by the NoGitCacheGc switch.
    5. Remove old Scoop app versions and installer caches via `scoop cleanup *`.
       Guarded by a Scoop presence check so the step is a no-op when Scoop is
       not yet installed (e.g. before the first apply.ps1 run).
    6. Remove locally installed Ollama models absent from the declarative manifest
       at src/modules/ai/models.json.  Uses Invoke-AISync -GcOnly so no new
       model pulls are triggered — GC only reclaims space.  Guarded by an ollama
       presence check so the step is a no-op when Ollama is not installed.
    7. Remove stale VM build artifacts (Packer directories, pre-built disk
       images) for VMs no longer declared in src/modules/VMs.json.
       Guarded by the NoVMGc switch.
    8. Rotate managed log files via copy-truncate using rotation parameters
       from src/modules/services.json.
       Guarded by the NoLogGc switch.

  All file operations are scoped to the primary user profile.  The script is
  idempotent and safe to re-run.

.PARAMETER ModuleDir
  Path to the Windows helper module directory. When omitted, auto-derives
  from RepoRoot as src\hosts\Windows\modules so callers can skip it when
  RepoRoot is provided (default: '').

.PARAMETER NoNixGc
  Accepted but ignored on Windows (POSIX-only) (default: $false).

.PARAMETER NoHmGc
  Accepted but ignored on Windows (POSIX-only) (default: $false).

.PARAMETER NoToolCacheGc
  Skip bun/cargo/rustc/uv and repo-local .direnv cache gc (default: $false).

.PARAMETER NoGitTemplateGc
  Skip stale .git sample hooks and description file cleanup under ~/dev (default: $false).

.PARAMETER NoGitCacheGc
  Skip stale .git cache/state cleanup and git gc --auto in repos under ~/dev (default: $false).

.PARAMETER NoOllamaGc
  Skip Ollama orphaned model removal even when ollama is installed (default: $false).

.PARAMETER NoScoopGc
  Skip Scoop cache and old-version gc even when Scoop is installed (default: $false).

.PARAMETER NoWallpaperGc
  Skip stale wallpaper file gc (default: $false).

.PARAMETER NoLogGc
  Skip log rotation (default: $false).

.PARAMETER NoJournaldGc
  Accepted but ignored on Windows (POSIX-only) (default: $false).

.PARAMETER LogMaxSize
  Log rotation max file size in bytes before rotation (default: from services.schema.json loggingEntry default).

.PARAMETER LogMaxFiles
  Number of rotated archives to keep (default: from services.schema.json loggingEntry default).

.PARAMETER LogCompress
  Whether to compress rotated logs (default: from services.schema.json loggingEntry default).

.PARAMETER NoVMGc
  Skip stale VM artifact removal (default: $false).

.PARAMETER Expiry
  Master expiry override for both HM and Nix GC durations (e.g. "14d", "30d") (default: "7d"). Accepted but ignored on Windows (POSIX-only).

.PARAMETER HmExpiry
  Home Manager generation expiry duration in nix format (e.g. "7d") (default: "7d"). Accepted but ignored on Windows (POSIX-only).

.PARAMETER NixExpiry
  Nix store GC --delete-older-than duration (e.g. "7d", "30d") (default: "7d"). Accepted but ignored on Windows (POSIX-only).

.EXAMPLE
  .\scripts\gc.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -RepoRoot "C:\Users\admin\nucleus"
  .\scripts\gc.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -RepoRoot "C:\Users\admin\nucleus" -NoToolCacheGc

.NOTES
  Environment variables: NUCLEUS_GC_MODULE_DIR, NUCLEUS_GC_NO_NIX, NUCLEUS_GC_NO_HM, NUCLEUS_GC_NO_TOOL_CACHE_GC, NUCLEUS_GC_NO_GIT_TEMPLATE_GC, NUCLEUS_GC_NO_GIT_CACHE_GC, NUCLEUS_GC_NO_OLLAMA_GC, NUCLEUS_GC_NO_SCOOP_GC, NUCLEUS_GC_NO_SCCACHE_GC, NUCLEUS_GC_NO_WALLPAPER_GC, NUCLEUS_GC_NO_VM_GC, NUCLEUS_GC_EXPIRY, NUCLEUS_GC_HM_EXPIRY, NUCLEUS_GC_NIX_EXPIRY, NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [string]$ModuleDir = $(if ($env:NUCLEUS_GC_MODULE_DIR) { $env:NUCLEUS_GC_MODULE_DIR } else { '' }),
  [switch]$NoNixGc = { $env:NUCLEUS_GC_NO_NIX -eq 'true' }.Invoke(),
  [switch]$NoHmGc = { $env:NUCLEUS_GC_NO_HM -eq 'true' }.Invoke(),
  [switch]$NoToolCacheGc = { $env:NUCLEUS_GC_NO_TOOL_CACHE_GC -eq 'true' }.Invoke(),
  [switch]$NoGitTemplateGc = { $env:NUCLEUS_GC_NO_GIT_TEMPLATE_GC -eq 'true' }.Invoke(),
  [switch]$NoGitCacheGc = { $env:NUCLEUS_GC_NO_GIT_CACHE_GC -eq 'true' }.Invoke(),
  [switch]$NoOllamaGc = { $env:NUCLEUS_GC_NO_OLLAMA_GC -eq 'true' }.Invoke(),
  [switch]$NoScoopGc = { $env:NUCLEUS_GC_NO_SCOOP_GC -eq 'true' }.Invoke(),
  [switch]$NoSccacheGc = { $env:NUCLEUS_GC_NO_SCCACHE_GC -eq 'true' }.Invoke(),
  [switch]$NoWallpaperGc = { $env:NUCLEUS_GC_NO_WALLPAPER_GC -eq 'true' }.Invoke(),
  [switch]$NoVMGc = { $env:NUCLEUS_GC_NO_VM_GC -eq 'true' }.Invoke(),
  [switch]$NoLogGc = { $env:NUCLEUS_GC_NO_LOG_GC -eq 'true' }.Invoke(),
  [switch]$NoJournaldGc = { $env:NUCLEUS_GC_NO_JOURNALD_GC -eq 'true' }.Invoke(),
  [string]$LogMaxSize = $(if ($env:NUCLEUS_GC_LOG_MAX_SIZE) { $env:NUCLEUS_GC_LOG_MAX_SIZE } else { '' }),
  [string]$LogMaxFiles = $(if ($env:NUCLEUS_GC_LOG_MAX_FILES) { $env:NUCLEUS_GC_LOG_MAX_FILES } else { '' }),
  [string]$LogCompress = $(if ($env:NUCLEUS_GC_LOG_COMPRESS) { $env:NUCLEUS_GC_LOG_COMPRESS } else { '' }),
  [string]$Expiry = $(if ($env:NUCLEUS_GC_EXPIRY) { $env:NUCLEUS_GC_EXPIRY } else { '' }),
  [string]$HmExpiry = $(if ($env:NUCLEUS_GC_HM_EXPIRY) { $env:NUCLEUS_GC_HM_EXPIRY } else { '' }),
  [string]$NixExpiry = $(if ($env:NUCLEUS_GC_NIX_EXPIRY) { $env:NUCLEUS_GC_NIX_EXPIRY } else { '' }),
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) {
  $env:NUCLEUS_REPO_ROOT
} else {
  # check-suppress:suppression_doc: probe -- path may not exist; $null check handles absence.
  $candidate = Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue
  if ($candidate -and (Test-Path "$candidate\src\flake.nix")) {
    $candidate
  } else {
    # check-suppress:suppression_doc: probe -- may not be in a git repo; $null check below handles absence.
    $gitRoot = & git -C (Get-Location).Path rev-parse --show-toplevel 2>$null | Out-String
    $gitRoot = $gitRoot.Trim()
    if (-not [string]::IsNullOrWhiteSpace($gitRoot) -and (Test-Path -Path $gitRoot -PathType Container)) {
      $gitRoot
    } else {
      Join-Path $HOME 'dev\nucleus'
    }
  }
}
if ([string]::IsNullOrWhiteSpace($ModuleDir)) {
  $ModuleDir = Join-Path $RepoRoot 'src\hosts\Windows\modules'
}

# -NoNixGc, -NoHmGc, and -NoJournaldGc are accepted but ignored on Windows
# (POSIX-only options from gc.sh). Accepted for cross-platform CLI parity.
if ($NoNixGc) {
  Write-NucleusWarning "-NoNixGc accepted but ignored on Windows (POSIX-only)"
}
if ($NoHmGc) {
  Write-NucleusWarning "-NoHmGc accepted but ignored on Windows (POSIX-only)"
}
if ($NoJournaldGc) {
  Write-NucleusWarning "-NoJournaldGc accepted but ignored on Windows (POSIX-only)"
}

# -Expiry, -HmExpiry, -NixExpiry are accepted but ignored on Windows
# (POSIX-only options from gc.sh). Accepted for cross-platform CLI parity.
if ($Expiry) {
  Write-NucleusWarning "-Expiry accepted but ignored on Windows (POSIX-only)"
}
if ($HmExpiry) {
  Write-NucleusWarning "-HmExpiry accepted but ignored on Windows (POSIX-only)"
}
if ($NixExpiry) {
  Write-NucleusWarning "-NixExpiry accepted but ignored on Windows (POSIX-only)"
}

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
$resolvedRepoRoot  = (Resolve-Path -Path $RepoRoot).Path

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
    Write-NucleusWarning "failed to gc $Label at '$Path' — $($_.Exception.Message)"
  }
}

function Remove-VMGcItem {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileSystemInfo]$Item,

    [Parameter(Mandatory = $true)]
    [string]$Label,

    [switch]$Recurse
  )

  if (-not $PSCmdlet.ShouldProcess($Item.FullName, "Remove $Label")) {
    return
  }

  try {
    if ($Recurse) {
      Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
    } else {
      Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
    }
    Write-NucleusInfo "removed $Label '$($Item.Name)'"
  }
  catch {
    Write-NucleusWarning "failed to remove $Label '$($Item.FullName)' — $($_.Exception.Message)"
  }
}

function Clear-GitTemplateBatch {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$DevRoot
  )

  if (-not (Test-Path -LiteralPath $DevRoot -PathType Container)) {
    return
  }

  # check-suppress:suppression_doc: ~/dev may not exist or contain .git dirs; silent skip is intentional
  $gitDirs = Get-ChildItem -LiteralPath $DevRoot -Directory -Recurse -Filter '.git' -Force -ErrorAction SilentlyContinue
  foreach ($gitDir in $gitDirs) {
    $hooksDir = Join-Path -Path $gitDir.FullName -ChildPath 'hooks'
    $descPath = Join-Path -Path $gitDir.FullName -ChildPath 'description'

    if (-not $PSCmdlet.ShouldProcess($gitDir.FullName, "Clear Git template boilerplate")) {
      continue
    }

    try {
      if (Test-Path -LiteralPath $hooksDir -PathType Container) {
        Get-ChildItem -LiteralPath $hooksDir -Filter '*.sample' -Force -ErrorAction Stop |
          Remove-Item -Force -ErrorAction Stop
      }
      if (Test-Path -LiteralPath $descPath -PathType Leaf) {
        Remove-Item -LiteralPath $descPath -Force -ErrorAction Stop
      }
    }
    catch {
      Write-NucleusWarning "failed to clear template files in '$($gitDir.FullName)' — $($_.Exception.Message)"
    }
  }
}

function Clear-GitCache {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$DevRoot
  )

  if (-not (Test-Path -LiteralPath $DevRoot -PathType Container)) {
    return
  }

  # check-suppress:suppression_doc: ~/dev may not exist or contain .git dirs; silent skip is intentional
  $gitDirs = Get-ChildItem -LiteralPath $DevRoot -Directory -Recurse -Filter '.git' -Force -ErrorAction SilentlyContinue
  foreach ($gitDir in $gitDirs) {
    $repoRoot = $gitDir.Parent.FullName

    if (-not $PSCmdlet.ShouldProcess($repoRoot, "Clear Git cache and state files")) {
      continue
    }

    try {
      # Detect active Git operation.
      $activeOp = $false
      $activeMarkers = @(
        'MERGE_HEAD', 'rebase-merge', 'rebase-apply', 'BISECT_LOG',
        'CHERRY_PICK_HEAD', 'REVERT_HEAD'
      )
      foreach ($marker in $activeMarkers) {
        $markerPath = Join-Path $gitDir.FullName $marker
        # check-suppress:suppression_doc: probe -- marker may not exist; silent skip is intentional
        if (Test-Path -LiteralPath $markerPath -PathType Container -ErrorAction SilentlyContinue) {
          $activeOp = $true
          break
        }
        # check-suppress:suppression_doc: probe -- marker may not exist; silent skip is intentional
        if (Test-Path -LiteralPath $markerPath -PathType Leaf -ErrorAction SilentlyContinue) {
          $activeOp = $true
          break
        }
      }

      # Remove gitk cache.
      $gitkCache = Join-Path $gitDir.FullName 'gitk.cache'
      if (Test-Path -LiteralPath $gitkCache -PathType Leaf) {
        Remove-Item -LiteralPath $gitkCache -Force -ErrorAction Stop
      }

      # Remove gc.log (allows git gc --auto to run again).
      $gcLog = Join-Path $gitDir.FullName 'gc.log'
      if (Test-Path -LiteralPath $gcLog -PathType Leaf) {
        Remove-Item -LiteralPath $gcLog -Force -ErrorAction Stop
      }

      # Remove lock files except index.lock.
      # check-suppress:suppression_doc: probe -- lock files may not exist; empty result is handled
      $lockFiles = Get-ChildItem -LiteralPath $gitDir.FullName -Filter '*.lock' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'index.lock' }  # ref: allow-and-deny-lists.instructions.md#A5 -- Git invariant; index.lock must never be cleaned
      foreach ($lockFile in $lockFiles) {
        Remove-Item -LiteralPath $lockFile.FullName -Force -ErrorAction Stop
      }

      # Remove stale state files when no active operation.
      # Uses dynamic glob patterns to discover stale files, so new Git state
      # files are automatically picked up without maintaining a hard-coded list.
      if (-not $activeOp) {
        $stateFiles = Get-ChildItem -LiteralPath $gitDir.FullName -File |
          Where-Object { $_.Name -match '(_HEAD$|^BISECT_|^AUTO_MERGE$|^SQUASH_MSG$)' }
        foreach ($stateFile in $stateFiles) {
          Remove-Item -LiteralPath $stateFile.FullName -Force -ErrorAction Stop
        }
      }

      # Remove deprecated directories if empty.
      $depDirs = @('branches', 'remotes')
      foreach ($depDir in $depDirs) {
        $depPath = Join-Path $gitDir.FullName $depDir
        if (Test-Path -LiteralPath $depPath -PathType Container) {
          # check-suppress:suppression_doc: probe -- dir may already be empty; empty result is handled
          $depChildren = Get-ChildItem -LiteralPath $depPath -Force -ErrorAction SilentlyContinue
          if ($null -eq $depChildren -or $depChildren.Count -eq 0) {
            Remove-Item -LiteralPath $depPath -Force -ErrorAction Stop
          }
        }
      }

      # Remove refs/original/ via git update-ref (handles packed-refs).
      # check-suppress:suppression_doc: refs/original/ may not exist; empty/null result is handled
      $originalRefs = & git -C $repoRoot for-each-ref --format='%(refname)' refs/original/ 2>$null
      if ($originalRefs) {
        $originalRefs.Trim() -split "`n" | ForEach-Object {
          $ref = $_.Trim()
          if ($ref) {
            # check-suppress:suppression_doc: ref may have been deleted by concurrent gc
            & git -C $repoRoot update-ref -d $ref 2>$null
          }
        }
        $originalDir = Join-Path $gitDir.FullName 'refs\original'
        if (Test-Path -LiteralPath $originalDir -PathType Container) {
          # check-suppress:suppression_doc: probe -- dir may not exist or may have leftover refs
          $originalChildren = Get-ChildItem -LiteralPath $originalDir -Force -ErrorAction SilentlyContinue
          if ($null -eq $originalChildren -or $originalChildren.Count -eq 0) {
            Remove-Item -LiteralPath $originalDir -Force -ErrorAction Stop
          }
        }
      }

      # Run git gc --auto (delegates object pruning, reflog expiry, etc. to Git).
      # check-suppress:suppression_doc: some repos may fail during gc; best-effort
      & git -C $repoRoot gc --auto 2>$null
    }
    catch {
      Write-NucleusWarning "failed to clear cache/state files in '$($gitDir.FullName)' — $($_.Exception.Message)"
    }
  }
}

# Load only the modules required by this script.
. (Join-Path -Path $resolvedModuleDir -ChildPath "ConfigHelpers.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "remove-stalewallpaper.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-AISync.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-LogManagement.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-SccacheManagement.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "ManagedPaths.ps1")

# ---- Step 1: stale wallpaper gc ----------------------------------------
if (-not $NoWallpaperGc) {
  $wallpaperOutputDir = Join-Path -Path $env:USERPROFILE -ChildPath "Pictures\wallpapers"
  Remove-StaleWallpaper -RepoRoot $resolvedRepoRoot -User $env:USERNAME -OutputDir $wallpaperOutputDir
}

# ---- Step 2: tool cache gc -------------------------------------------------
if (-not $NoToolCacheGc) {
  $bunCacheDir = Join-Path $HOME ".bun\install\cache"
  $cargoBinstallCacheDir = Join-Path $env:LOCALAPPDATA "cargo-binstall\cache"
  $rustupTmpDir = Join-Path $HOME ".rustup\tmp"
  $uvCacheDir = Join-Path $env:LOCALAPPDATA "uv\cache"
  $repoDirenvDir = Join-Path $resolvedRepoRoot ".direnv"

  Clear-DirectoryContentsIfPresent -Path $bunCacheDir -Label "bun install cache"
  Clear-DirectoryContentsIfPresent -Path $cargoBinstallCacheDir -Label "cargo-binstall cache"
  Clear-DirectoryContentsIfPresent -Path $rustupTmpDir -Label "rustup temporary cache"

  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  $cargoCacheCmd = Get-Command -Name "cargo-cache" -ErrorAction SilentlyContinue
  if ($null -eq $cargoCacheCmd) {
    Write-NucleusInfo "cargo-cache unavailable; skipping cargo cache gc"
  } else {
    & $cargoCacheCmd.Source -r all
  }

  Clear-DirectoryContentsIfPresent -Path $uvCacheDir -Label "uv cache"

  if (Test-Path -LiteralPath $repoDirenvDir -PathType Container) {
    try {
      Remove-Item -LiteralPath $repoDirenvDir -Recurse -Force -ErrorAction Stop
    }
    catch {
      Write-NucleusWarning "failed to remove repo-local direnv cache '$repoDirenvDir' — $($_.Exception.Message)"
    }
  }
}

# ---- Step 3: remove stale .git boilerplate from ~/dev -----------------------
if (-not $NoGitTemplateGc) {
  $devRoot = Join-Path $HOME 'dev'
  Clear-GitTemplateBatch -DevRoot $devRoot
}

# ---- Step 4: remove stale .git cache/state files from ~/dev -----------------
if (-not $NoGitCacheGc) {
  $devRoot = Join-Path $HOME 'dev'
  Clear-GitCache -DevRoot $devRoot
}

# ---- Step 5: Scoop cache and old-version cleanup ----------------------------
if (-not $NoScoopGc) {
  $scoopShims = Get-NucleusScoopShimsDir
  $scoopCmd   = Join-Path $scoopShims "scoop.cmd"
  if (-not (Test-Path $scoopCmd)) {
    Write-NucleusInfo "scoop not installed; skipping scoop gc"
  } else {
    Add-NucleusPathEntry -Path $scoopShims
    Write-NucleusInfo "running scoop cleanup..."
    scoop cleanup *
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusWarning "scoop cleanup exited with code $LASTEXITCODE"
    }
  }
}

# ---- Step 6: Ollama orphaned model gc --------------------------------------
if (-not $NoOllamaGc) {
  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  $ollamaCmd = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaCmd) {
    Write-NucleusInfo "ollama not installed; skipping ollama model gc"
  } else {
    Invoke-AISync -GcOnly -RepoRoot $resolvedRepoRoot -ServerReadyTimeoutSeconds 0
  }
}

# ---- Step 7b: sccache cache clearing ----------------------------------------
if (-not $NoSccacheGc) {
  Clear-SccacheCache
}

# ---- Step 7: stale VM artifact removal ------------------------------------
if (-not $NoVMGc) {
  $vmDir = Join-Path $env:USERPROFILE "virtual machines"
  $imagesDir = Join-Path $vmDir "images"
  $manifest = Join-Path $resolvedRepoRoot "src\modules\VMs.json"

  # If VM directories do not exist, there is nothing to clean.
  if (-not (Test-Path -LiteralPath $vmDir -PathType Container)) {
    Write-NucleusInfo "VM directory not found; skipping VM artifact gc"
  } elseif (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    Write-NucleusWarning "manifest '$manifest' not found; skipping VM artifact gc"
  } elseif (Test-Path -LiteralPath $imagesDir -PathType Container) {
    # Remove temporary Packer build directories.
    # check-suppress:suppression_doc: probe -- temporary build directories may not exist; ForEach-Object handles empty result.
    Get-ChildItem -LiteralPath $imagesDir -Filter "*-build" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      Remove-VMGcItem -Item $_ -Label "temporary VM build directory" -Recurse
    }

    # Remove leftover Packer temporary build directories (dot-prefixed, from interrupted runs).
    # check-suppress:suppression_doc: probe -- stale temporary directories may not exist; Where-Object handles empty result.
    Get-ChildItem -LiteralPath $imagesDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\..+' } | ForEach-Object {
      Remove-VMGcItem -Item $_ -Label "stale Packer temporary build directory" -Recurse
    }

    # WHY: keep-set has one source of truth in Invoke-VMSetup.ps1 — the old
    # enabled-only name sweep deleted non-regenerable goldens/bases of
    # disabled/other-host guests (e.g. Android-system.qcow2, Windows.qcow2);
    # Invoke-VMSetup -Gc preserves every manifest guest by default
    # (-GcDisabled narrows). Start/stop scripts are regenerated for every
    # manifest guest (Pass B) and stripped by pack; descriptor staleness is
    # owned by Invoke-GcOrphanDescriptor. gc.ps1 has no -DryRun mode, so none
    # is passed (the module accepts -DryRun for direct use).
    $vmSetupModule = Join-Path $resolvedRepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
    if (-not (Test-Path -LiteralPath $vmSetupModule -PathType Leaf)) {
      Write-NucleusWarning "Invoke-VMSetup module not found at $vmSetupModule; skipping VM artifact gc"
    } else {
      . $vmSetupModule
      Invoke-VMSetup -RepoRoot $resolvedRepoRoot -Gc -GcDisabled:$false
    }
  }
}

# ---- Step 8: log rotation -------------------------------------------------
if (-not $NoLogGc) {
  $servicesJson = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\services.json"
  $servicesSchemaJson = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\services.schema.json"
  if (-not (Test-Path -LiteralPath $servicesJson -PathType Leaf)) {
    Write-NucleusWarning "services.json not found; skipping log rotation"
  } else {
    try {
      $schemaContent = Get-Content -LiteralPath $servicesSchemaJson -Raw | ConvertFrom-Json
      $loggingDefaults = $schemaContent.definitions.loggingEntry.properties
    } catch {
      Write-NucleusWarning "failed to parse services.schema.json; using hardcoded defaults — $($_.Exception.Message)"
      $loggingDefaults = $null
    }

    $logMaxSize = if ($LogMaxSize) { [int]$LogMaxSize } elseif ($loggingDefaults.maxSize.default) { [int]$loggingDefaults.maxSize.default } else { 10000000 } # bytes
    $logMaxFiles = if ($LogMaxFiles) { [int]$LogMaxFiles } elseif ($loggingDefaults.maxFiles.default) { [int]$loggingDefaults.maxFiles.default } else { 4 }
    $logCompress = if ($LogCompress) { [bool]::Parse($LogCompress) } elseif ($null -ne $loggingDefaults.compress.default) { [bool]$loggingDefaults.compress.default } else { $true }

    $logDir = Get-NucleusLogDir
    $systemLogDir = Get-NucleusSystemLogDir
    $logExpiry = if ($Expiry) { $Expiry } elseif ($env:NUCLEUS_GC_EXPIRY) { $env:NUCLEUS_GC_EXPIRY } else { '7d' }

    Invoke-LogRotation -Path $logDir -MaxSize $logMaxSize -MaxFiles $logMaxFiles -Compress $logCompress
    Invoke-LogExpiry -Path $logDir -Expiry $logExpiry

    if ($systemLogDir -and ($systemLogDir -ne $logDir)) {
      Invoke-LogRotation -Path $systemLogDir -MaxSize $logMaxSize -MaxFiles $logMaxFiles -Compress $logCompress
      Invoke-LogExpiry -Path $systemLogDir -Expiry $logExpiry
    }
  }
}

Write-NucleusDone
