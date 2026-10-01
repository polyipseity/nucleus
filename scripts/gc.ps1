<#
.SYNOPSIS
  Perform bounded garbage collection on Windows hosts.

.DESCRIPTION
  Windows counterpart to scripts/gc.sh. Every step is independently skippable
  and scoped to the primary user profile, so the script is idempotent.

  -DryRun reports each destructive step through Write-NucleusDryRun and removes
  nothing. The step guards make a preview impossible to turn into a real run.

.PARAMETER DryRun
  Report what would be collected and remove nothing (default: $false).

.PARAMETER LogMaxSize
  Rotation threshold in bytes (default: loggingEntry.maxSize in services.schema.json).

.PARAMETER LogMaxFiles
  Rotated archives to keep (default: loggingEntry.maxFiles in services.schema.json).

.PARAMETER LogCompress
  Whether to gzip rotated logs (default: loggingEntry.compress in services.schema.json).

.PARAMETER GCVMData
  Collect orphaned VM data (default: $false). Runs vm.sh gc --gc-data, which is
  what gc.sh does when asked to.

.NOTES
  Environment variables: NUCLEUS_GC_HM_EXPIRY, NUCLEUS_GC_LOG_COMPRESS, NUCLEUS_GC_LOG_MAX_FILES, NUCLEUS_GC_LOG_MAX_SIZE, NUCLEUS_GC_MODULE_DIR, NUCLEUS_GC_NIX_EXPIRY, NUCLEUS_LOG_EXPIRY, NUCLEUS_REPO_ROOT.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('all', 'cleanup-nix', 'preferences')]
  [string]$Action = 'all',
  [string]$ModuleDir = $(if ($env:NUCLEUS_GC_MODULE_DIR) { $env:NUCLEUS_GC_MODULE_DIR } else { '' }),
  [switch]$DryRun,
  [switch]$NoNixGc,
  [switch]$NoHmGc,
  [switch]$NoToolCacheGc,
  [switch]$NoGitCacheGc,
  [switch]$NoOllamaGc,
  [switch]$NoScoopGc,
  [switch]$NoSccacheGc,
  [switch]$NoWallpaperGc,
  [switch]$NoVMGc,
  [switch]$GCVMData,
  [switch]$NoLogGc,
  [switch]$NoJournaldGc,
  [switch]$NoSystemGc,
  [switch]$NoNixArtifactsGc,
  [switch]$NoDuperemoveGc,
  [string]$LogMaxSize = $(if ($env:NUCLEUS_GC_LOG_MAX_SIZE) { $env:NUCLEUS_GC_LOG_MAX_SIZE } else { '' }),
  [string]$LogMaxFiles = $(if ($env:NUCLEUS_GC_LOG_MAX_FILES) { $env:NUCLEUS_GC_LOG_MAX_FILES } else { '' }),
  [string]$LogCompress = $(if ($env:NUCLEUS_GC_LOG_COMPRESS) { $env:NUCLEUS_GC_LOG_COMPRESS } else { '' }),
  [string]$Expiry,
  [string]$HmExpiry = $(if ($env:NUCLEUS_GC_HM_EXPIRY) { $env:NUCLEUS_GC_HM_EXPIRY } else { '' }),
  [string]$NixExpiry = $(if ($env:NUCLEUS_GC_NIX_EXPIRY) { $env:NUCLEUS_GC_NIX_EXPIRY } else { '' }),
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
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
  $ModuleDir = Join-Path $RepoRoot 'src\platforms\Windows\modules'
}

# WHY accepted: cross-platform CLI parity with gc.sh, which carries the same
# flags for nix, system GC, nix artifacts, duperemove and the expiry values.
if ($NoNixGc) {
  Write-NucleusWarning "-NoNixGc accepted but ignored on Windows (POSIX-only)"
}
if ($NoHmGc) {
  Write-NucleusWarning "-NoHmGc accepted but ignored on Windows (POSIX-only)"
}
if ($NoJournaldGc) {
  Write-NucleusWarning "-NoJournaldGc accepted but ignored on Windows (POSIX-only)"
}

if ($NoSystemGc) {
  Write-NucleusWarning "-NoSystemGc accepted but ignored on Windows (POSIX-only)"
}

if ($NoNixArtifactsGc) {
  Write-NucleusWarning "-NoNixArtifactsGc accepted but ignored on Windows (POSIX-only)"
}

if ($NoDuperemoveGc) {
  Write-NucleusWarning "-NoDuperemoveGc accepted but ignored on Windows (POSIX-only)"
}

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
    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    if ($DryRun) {
      Write-NucleusDryRun "would clear $($entries.Count) item(s) from $Label at '$Path'"
      return
    }
    $entries | Remove-Item -Recurse -Force -ErrorAction Stop
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

  if ($DryRun) {
    Write-NucleusDryRun "would remove $Label '$($Item.Name)'"
    return
  }

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

    if ($DryRun) {
      Write-NucleusDryRun "would clear git cache and state files and run 'git gc --auto' in '$repoRoot'"
      continue
    }

    if (-not $PSCmdlet.ShouldProcess($repoRoot, "Clear Git cache and state files")) {
      continue
    }

    try {
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

      $gitkCache = Join-Path $gitDir.FullName 'gitk.cache'
      if (Test-Path -LiteralPath $gitkCache -PathType Leaf) {
        Remove-Item -LiteralPath $gitkCache -Force -ErrorAction Stop
      }

      # WHY remove gc.log: it is what keeps `git gc --auto` from running again.
      $gcLog = Join-Path $gitDir.FullName 'gc.log'
      if (Test-Path -LiteralPath $gcLog -PathType Leaf) {
        Remove-Item -LiteralPath $gcLog -Force -ErrorAction Stop
      }

      # check-suppress:suppression_doc: probe -- lock files may not exist; empty result is handled
      $lockFiles = Get-ChildItem -LiteralPath $gitDir.FullName -Filter '*.lock' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'index.lock' }  # ref: allow-and-deny-lists.instructions.md#A5 -- Git invariant; index.lock must never be cleaned
      foreach ($lockFile in $lockFiles) {
        Remove-Item -LiteralPath $lockFile.FullName -Force -ErrorAction Stop
      }

      # WHY the glob: new Git state files are picked up without a hard-coded list.
      if (-not $activeOp) {
        $stateFiles = Get-ChildItem -LiteralPath $gitDir.FullName -File |
          Where-Object { $_.Name -match '(_HEAD$|^BISECT_|^AUTO_MERGE$|^SQUASH_MSG$)' }
        foreach ($stateFile in $stateFiles) {
          Remove-Item -LiteralPath $stateFile.FullName -Force -ErrorAction Stop
        }
      }

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

      # WHY update-ref: it also sees refs packed into packed-refs.
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

      # WHY delegate: Git owns object pruning and reflog expiry.
      # check-suppress:suppression_doc: some repos may fail during gc; best-effort
      & git -C $repoRoot gc --auto 2>$null
    }
    catch {
      Write-NucleusWarning "failed to clear cache/state files in '$($gitDir.FullName)' — $($_.Exception.Message)"
    }
  }
}

function Invoke-CleanupNix {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @()
  )

  $Verbose = ($VerbosePreference -eq 'Continue')

  foreach ($_arg in $Arguments) {
    switch ($_arg) {
      '-WhatIf'  { $WhatIfPreference = $true }  # routes ShouldProcess to DryRun branch
      '-Verbose' { $Verbose = $true }
      '-h'      { Write-Output "Usage: gc.ps1 cleanup-nix [-WhatIf] [-Verbose]"; return }
      '--help'  { Write-Output "Usage: gc.ps1 cleanup-nix [-WhatIf] [-Verbose]"; return }
      default   {
        Write-NucleusError -CommandName cleanup-nix "unsupported argument '$_arg'"
        exit 1
      }
    }
  }

  $_found = $false

  # WHY a manual walk: Get-ChildItem -Recurse follows reparse points, and the
  # index cursor avoids range-operator edge cases on single-element arrays.
  $_dirIndex = 0
  $_directories = @($resolvedRepoRoot)

  while ($_dirIndex -lt $_directories.Count) {
    $_dir = $_directories[$_dirIndex]
    $_dirIndex++

    foreach ($_pattern in @('result', 'result-*')) {
      # check-suppress:suppression_doc: probe -- result symlinks may not exist; ForEach-Object handles absent results gracefully.
      Get-ChildItem -Path $_dir -Filter $_pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LinkType -eq 'SymbolicLink') {
          $_target = $_.Target
          if ($PSCmdlet.ShouldProcess($_.FullName, "Remove stale Nix build symlink")) {
            Remove-Item -LiteralPath $_.FullName -Force
            Write-NucleusInfo -CommandName cleanup-nix "removed stale Nix build symlink: $($_.FullName) -> $_target"
          } else {
            Write-NucleusDryRun -CommandName cleanup-nix "would remove stale Nix build symlink: $($_.FullName) -> $_target"
          }
        } elseif ($_.PSIsContainer -or (-not $_.LinkType)) {
          if ($Verbose) {
            Write-NucleusInfo -CommandName cleanup-nix "found non-symlink at $($_.FullName) — skipping (not a Nix build artifact)"
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
    Write-NucleusInfo -CommandName cleanup-nix "no stale Nix build artifacts found."
  }
}

# Load only the modules required by this script.
. (Join-Path -Path $resolvedModuleDir -ChildPath "ConfigHelpers.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "remove-stalewallpaper.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-AISync.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-LogManagement.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-SccacheManagement.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "ManagedPaths.ps1")

switch ($Action) {
  'cleanup-nix' {
    Invoke-CleanupNix -WhatIf:$DryRun
  }
  'preferences' {
    Write-NucleusInfo "preferences gc is macOS-only; no Windows action performed"
    Write-NucleusDone
  }
  'all' {
    # ---- Step 1: stale wallpaper gc ----------------------------------------
    if (-not $NoWallpaperGc) {
  $wallpaperOutputDir = Join-Path -Path $env:USERPROFILE -ChildPath "Pictures\wallpapers"
  if ($DryRun) {
    Write-NucleusDryRun "would remove stale wallpapers from '$wallpaperOutputDir'"
  } else {
    Remove-StaleWallpaper -RepoRoot $resolvedRepoRoot -User $env:USERNAME -OutputDir $wallpaperOutputDir
  }
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
  } elseif ($DryRun) {
    Write-NucleusDryRun "would run 'cargo-cache -r all'"
  } else {
    & $cargoCacheCmd.Source -r all
  }

  Clear-DirectoryContentsIfPresent -Path $uvCacheDir -Label "uv cache"

  if (Test-Path -LiteralPath $repoDirenvDir -PathType Container) {
    try {
      if ($DryRun) {
        Write-NucleusDryRun "would remove repo-local direnv cache '$repoDirenvDir'"
      } else {
        Remove-Item -LiteralPath $repoDirenvDir -Recurse -Force -ErrorAction Stop
      }
    }
    catch {
      Write-NucleusWarning "failed to remove repo-local direnv cache '$repoDirenvDir' — $($_.Exception.Message)"
    }
  }
}

# ---- Step 3: remove stale .git cache/state files from ~/dev -----------------
if (-not $NoGitCacheGc) {
  $devRoot = Join-Path $HOME 'dev'
  Clear-GitCache -DevRoot $devRoot
}

# ---- Step 4: Scoop cache and old-version cleanup ----------------------------
if (-not $NoScoopGc) {
  $scoopShims = Get-NucleusScoopShimsDir
  $scoopCmd   = Join-Path $scoopShims "scoop.cmd"
  if (-not (Test-Path $scoopCmd)) {
    Write-NucleusInfo "scoop not installed; skipping scoop gc"
  } else {
    Add-NucleusPathEntry -Path $scoopShims
    if ($DryRun) {
      Write-NucleusDryRun "would run 'scoop cleanup *'"
    } else {
      Write-NucleusInfo "running scoop cleanup..."
      scoop cleanup *
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning "scoop cleanup exited with code $LASTEXITCODE"
      }
    }
  }
}

# ---- Step 5: Ollama orphaned model gc --------------------------------------
if (-not $NoOllamaGc) {
  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  $ollamaCmd = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaCmd) {
    Write-NucleusInfo "ollama not installed; skipping ollama model gc"
  } elseif ($DryRun) {
    Write-NucleusDryRun "would remove Ollama models absent from the declarative manifest"
  } else {
    Invoke-AISync -GcOnly -RepoRoot $resolvedRepoRoot -ServerReadyTimeoutSeconds 0
  }
}

# ---- Step 7b: sccache cache clearing ----------------------------------------
if (-not $NoSccacheGc) {
  if ($DryRun) {
    Write-NucleusDryRun "would stop the sccache server and clear its cache"
  } else {
    Clear-SccacheCache
  }
}

# ---- Step 6: stale VM artifact removal ------------------------------------
if (-not $NoVMGc) {
  $vmDir = Join-Path $env:USERPROFILE "virtual machines"
  $srcDir = Join-Path $vmDir "src"
  $manifest = Join-Path $resolvedRepoRoot "src\modules\vms\VMs.json"

  if (-not (Test-Path -LiteralPath $vmDir -PathType Container)) {
    Write-NucleusInfo "VM directory not found; skipping VM artifact gc"
  } elseif (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    Write-NucleusWarning "manifest '$manifest' not found; skipping VM artifact gc"
  } elseif (Test-Path -LiteralPath $srcDir -PathType Container) {
    # Packer build dirs under src/<type>/Packer/.
    # check-suppress:suppression_doc: probe -- type directories may not exist; ForEach-Object handles empty result.
    Get-ChildItem -LiteralPath $srcDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $packerDir = Join-Path $_.FullName 'Packer'
      if (Test-Path -LiteralPath $packerDir -PathType Container) {
        Remove-VMGcItem -Item (Get-Item -LiteralPath $packerDir) -Label "temporary VM Packer directory" -Recurse
      }
    }

    # Dot-prefixed Packer dirs left by interrupted runs.
    # check-suppress:suppression_doc: probe -- type directories may not exist; ForEach-Object handles empty result.
    Get-ChildItem -LiteralPath $srcDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      # check-suppress:suppression_doc: probe -- stale temporary directories may not exist; Where-Object handles empty result.
      Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\..+' } |
        ForEach-Object {
          Remove-VMGcItem -Item $_ -Label "stale Packer temporary build directory" -Recurse
        }
    }

    # WHY the keep-set has one owner: the old enabled-only sweep deleted
    # non-regenerable system images of disabled or other-host guests, and
    # vm.sh gc preserves every manifest guest unless --gc-disabled narrows it.
    $vmSh = Join-Path $resolvedRepoRoot 'scripts\vm.sh'
    if (-not (Test-Path -LiteralPath $vmSh -PathType Leaf)) {
      Write-NucleusWarning "vm.sh not found at $vmSh; skipping VM artifact gc"
    } else {
      # WHY the switch is positive: gc.sh defaults vm_data_gc to false, and a
      # -NoVmDataGc spelling would default to $false, meaning do not skip.
      $vmGcArgs = @('gc')
      if ($GCVMData) { $vmGcArgs += '--gc-data' }
      if ($DryRun) {
        # WHY no second bash call: vm.sh accepts --dry-run, but previewing through a
        # script whose dry-run paths are not covered here would trade the point
        # of the switch for a prettier message.
        Write-NucleusDryRun "would run 'vm.sh gc' for stale VM artifacts"
      } else {
        & bash $vmSh @vmGcArgs
        # WHY read it here: a stale value from an earlier command would raise a
        # misleading warning on a dry run that ran nothing.
        if ($LASTEXITCODE -ne 0) {
          Write-NucleusWarning "vm.sh gc exited with code $LASTEXITCODE"
        }
      }
    }
  }
}

# ---- Step 7: log rotation -------------------------------------------------
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
    $logExpiry = if ($env:NUCLEUS_LOG_EXPIRY) { $env:NUCLEUS_LOG_EXPIRY } else { '7d' }

    if ($DryRun) {
      Write-NucleusDryRun "would rotate managed logs in '$logDir' and expire archives older than $logExpiry"
    } else {
      Invoke-LogRotation -Path $logDir -MaxSize $logMaxSize -MaxFiles $logMaxFiles -Compress $logCompress
      Invoke-LogExpiry -Path $logDir -Expiry $logExpiry
    }

    if ($systemLogDir -and ($systemLogDir -ne $logDir)) {
      if (Test-NucleusLogDirWritable -Path $systemLogDir) {
        if ($DryRun) {
          Write-NucleusDryRun "would rotate managed logs in '$systemLogDir' and expire archives older than $logExpiry"
        } else {
          Invoke-LogRotation -Path $systemLogDir -MaxSize $logMaxSize -MaxFiles $logMaxFiles -Compress $logCompress
          Invoke-LogExpiry -Path $systemLogDir -Expiry $logExpiry
        }
      } elseif ($DryRun) {
        Write-NucleusDryRun "would escalate system log rotation in '$systemLogDir' to the 'log-gc-system' scheduled task"
      } else {
        try {
          Start-ScheduledTask -TaskName 'log-gc-system' -TaskPath '\nucleus\' -ErrorAction Stop
          Write-NucleusNotice -CommandName log-gc "escalated system log rotation to 'log-gc-system' scheduled task"
        } catch {
          Write-NucleusWarning -CommandName log-gc "system log dir '$systemLogDir' not writable and cannot escalate; skipping"
        }
      }
    }
  }
}

  Write-NucleusDone
  }
}
