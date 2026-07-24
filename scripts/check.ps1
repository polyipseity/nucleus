# check.ps1 — Consolidated repository validation script (Windows).
#
# Runs all Windows-compatible repository checks in sequence:
#
# Checks are organized into topic groups. Within each group, checks are ordered
# alphabetically by their display name. Exceptions: dependency constraints may
# override alphabetical ordering (e.g., Lockfile validation must precede Locked
# DSC validation). New checks should be inserted at their alphabetical position
# within the appropriate group, respecting any dependency constraints.
#
# Toolchain checks (1-3):
#   1. Shell script linting (shellcheck) (stub on Windows)
#   2. PowerShell syntax validation
#   3. Packer template validation
#
# Nix checks (4-8, stubs on Windows):
#   4. Dead Nix code (stub)
#   5. Nix flake evaluation (stub)
#   6. Nix formatting (nixfmt) (stub)
#   7. Nix lint (nixf-tidy) (stub)
#   8. Stale Nix build artifact check
#
# Test suites (9-12, stubs on Windows):
#   9. Shell script validation tests (stub)
#  10. CWD-independence tests (stub)
#  11. Nix search path tests (stub)
#  12. Port utility function tests (stub)
#
# Data integrity (13-18):
# Data integrity (13-16):
#  13. Lockfile validation
#  14. Locked DSC validation
#  15. Schema validation (JSON/YAML)
#  16. Service registry validation
#
# Policy/verification (17-22):
#  17. YAML validation and linting (yamllint)
#  18. Package manager usage enforcement
#  19. Undocumented error suppression check
#  20. Online determinism checks (--verify mode only)
#  21. Config method compliance
#  22. Activation script token placeholder in comment check
#
# Mode taxonomy:
#   Always-run (no HAS_ARGS guard — run in both --full and --scoped):
#     - Stale Nix build artifact check        (step 8)
#     - Lockfile section validation           (step 13)
#     - Locked DSC validation                 (step 14)
#     - Service registry validation           (step 16)
#     - Package manager usage enforcement     (step 18)
#     - Config method compliance              (step 21)
#   Path-scopable (accept file filtering in both modes):
#     - PowerShell syntax validation          (step 2)
#     - Packer template validation            (step 3)
#     - Schema validation                     (step 15)
#     - YAML validation/linting               (step 17)
#     - Undocumented error suppression        (step 19)
#     - Activation script token placeholder   (step 22)
#
# Note: Steps 1, 4-7, 9-12 are stubs on Windows (POSIX/Nix toolchain not available).
#
# Output conventions:
#   All messages (info, success, skip, warning) go to stdout.
#   This differs from check.sh, which routes warnings to stderr — the
#   split is intentional per platform convention.
#   Use check.sh's header comment as the cross-reference source of truth
#   for the POSIX-side convention.
#
# Dependencies policy:
# Every external tool required by any check in this script MUST be declared in
# the pre-flight block below. Missing tools cause an immediate hard failure —
# checks MUST NEVER silently skip due to missing dependencies.
# The pre-flight block is the single source of truth for all tool requirements.
# To add a new tool-using check, first add it to pre-flight, then provision it
# on all target hosts.
#
# File discovery policy:
# All file lists in this script MUST be auto-discovered (Get-ChildItem, glob
# patterns). Hard-coded file paths in validation steps are not allowed.
#
# Tests (Nix test suite) are run separately via scripts/test.ps1.
# Step 1 is a POSIX-only stub (shellcheck not available on Windows).
# Steps 4-7, 9-12 are stubs (require Nix or bash — not available on Windows).
# Step 21 only runs with the --verify flag.
#
# Prerequisites:
#   - check-jsonschema (pip install check-jsonschema) for schema validation
#   - Ensure-Tool module (imported via pre-flight block) for tool validation
#   - powershell-yaml module (Install-Module powershell-yaml -Scope CurrentUser)
#     is required for locked DSC validation.
#   - yamllint (pip install yamllint) for YAML linting
#
# Arguments:
#   (none)        Paths may be provided as positional arguments; passed
#                 through to individual checkers that support path filtering.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
# By default, all checks run and failures accumulate (report-at-end).
# Use --fail-fast to exit immediately on the first failure.

#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
$exitCode = 0
$FAIL_FAST = $false
$VERIFY = $false
$SCOPED = $false
$FULL = $false
$positionalArgs = @()

# Output helpers — structured prefix pattern matching check.sh's lib.sh.
# Use these instead of raw Write-Output for all validation messages.
# Warnings are routed to stdout (PowerShell convention);
# compare with check.sh which routes warn() to stderr (POSIX convention).
function say { Write-Output "check: $args" }
function warn { Write-Output "check: warning: $args" }

# Process flags
foreach ($_arg in $args) {
  if ($_arg -eq '-h' -or $_arg -eq '--help') {
    Write-Output "Usage: check.ps1 [--fail-fast|--no-fail-fast] [--scoped|--full] [--verify] [path ...]"
    Write-Output "  Run all Windows-compatible repository validation checks in sequence."
    Write-Output "  Use --scoped to skip whole-repo checks (path-scoped mode), --full to force"
    Write-Output "  whole-repo checks even with paths. Default: scoped if paths given, full if not."
    Write-Output "  --fail-fast      Exit immediately on first failure (default: accumulate all)."
    Write-Output "  --no-fail-fast    Accumulate all failures (default)."
    Write-Output "  --verify         Additionally run online determinism checks (requires network)."
    exit 0
  } elseif ($_arg -eq '--fail-fast') {
    $FAIL_FAST = $true
  } elseif ($_arg -eq '--no-fail-fast') {
    $FAIL_FAST = $false
  } elseif ($_arg -eq '--scoped') {
    $SCOPED = $true
  } elseif ($_arg -eq '--full') {
    $FULL = $true
  } elseif ($_arg -eq '--verify') {
    $VERIFY = $true
  } else {
    $positionalArgs += $_arg
  }
}

# Validate mutual exclusivity: --scoped and --full cannot be combined.
if ($SCOPED -and $FULL) {
  Write-Output "check: error: cannot specify both --scoped and --full"
  exit 1
}

$HAS_ARGS = $positionalArgs.Count -gt 0
if ($SCOPED) { $HAS_ARGS = $true }
if ($FULL)   { $HAS_ARGS = $false }

# Group paths by extension — each sub-checker receives only files it understands.
$SH_FILES = @()
$NIX_FILES = @()
$PS1_FILES = @()
$PKR_FILES = @()
if ($HAS_ARGS) {
  foreach ($_f in $positionalArgs) {
    if ($_f -like '*.sh')      { $SH_FILES += $_f }
    if ($_f -like '*.nix')     { $NIX_FILES += $_f }
    if ($_f -like '*.ps1')     { $PS1_FILES += $_f }
    if ($_f -like '*.pkr.hcl') { $PKR_FILES += $_f }
  }
}
# cached file lists — used in full mode to avoid repeated Get-ChildItem traversals.
if (-not $HAS_ARGS) {
  $script:CachedNixFiles = Get-ChildItem -Recurse -Path "$RepoRoot/src" -Filter '*.nix' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object FullName
  $script:CachedYamlFiles = Get-ChildItem -Recurse -Path $RepoRoot -Include '*.yml','*.yaml' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object FullName
  $script:CachedJsonFiles = Get-ChildItem -Recurse -Path "$RepoRoot/src" -Include '*.json' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.Name -notlike '*.schema.json' } | Sort-Object FullName
  $script:CachedPs1Files = Get-ChildItem -Recurse -Path $RepoRoot -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object FullName
}

$_step = 0

# Pre-flight tool availability checks.
# All tools listed in Prerequisites must be present. Missing tools produce
# an immediate hard failure — run bootstrap or nucleus-apply to install them.
$modulesPath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules'
Import-Module (Join-Path $modulesPath 'Ensure-Tool.psm1') -Force
Ensure-Tool -Name 'powershell-yaml' -Type 'Module' -InstallCommand "Install-Module powershell-yaml -Scope CurrentUser -Force"
Ensure-Tool -Name 'packer' -Type 'Command' -InstallCommand "winget install Hashicorp.Packer"
Ensure-Tool -Name 'yamllint' -Type 'Command' -InstallCommand 'pip install yamllint'
Ensure-Tool -Name 'check-jsonschema' -Type 'Command' -InstallCommand 'pip install check-jsonschema'
# shellcheck is POSIX-native and not available on Windows.
# Use check.sh on WSL/Linux for shell script linting.

# ---------------------------------------------------------------------------
# 1. Shell script linting (shellcheck) — POSIX only (stub on Windows)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Shell script linting (shellcheck) ===" -f (++$_step))
say "skipping (requires POSIX shellcheck — not available natively on Windows; use WSL or check.sh)."

# ---------------------------------------------------------------------------
# 2. PowerShell syntax validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] PowerShell syntax validation ===" -f (++$_step))
if ($PS1_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-pwsh.ps1" -SyntaxOnly -Scoped $PS1_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-pwsh.ps1" -SyntaxOnly
} else {
  say "skipping (no PowerShell scripts to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
if ($FAIL_FAST -and $exitCode -ne 0) { exit $exitCode }

# ---------------------------------------------------------------------------
# 3. Packer template validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Packer template validation ===" -f (++$_step))
if ($PKR_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-packer.ps1" $PKR_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-packer.ps1"
} else {
  say "skipping (no Packer templates to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
if ($FAIL_FAST -and $exitCode -ne 0) { exit $exitCode }

# ---------------------------------------------------------------------------
# 4. Dead Nix code
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Dead Nix code ===" -f (++$_step))
say "skipping (requires Nix toolchain — not available on Windows)."

# ---------------------------------------------------------------------------
# 5. Nix flake evaluation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Nix flake evaluation ===" -f (++$_step))
say "skipping (requires Nix toolchain — not available on Windows)."

# ---------------------------------------------------------------------------
# 6. Nix formatting (nixfmt)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Nix formatting (nixfmt) ===" -f (++$_step))
say "skipping (requires Nix toolchain — not available on Windows)."

# ---------------------------------------------------------------------------
# 7. Nix lint (nixf-tidy)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Nix lint (nixf-tidy) ===" -f (++$_step))
say "skipping (requires Nix toolchain — not available on Windows)."

# ---------------------------------------------------------------------------
# 8. Stale Nix build artifact check
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Stale Nix build artifact check ===" -f (++$_step))
# Always-run: Stale Nix build artifact check
$_cnbaOutput = & "$PSScriptRoot\cleanup-nix.ps1" -WhatIf 2>&1
  $_cnbaFound = $_cnbaOutput | Select-String -Pattern 'would remove stale Nix build symlink'
  if ($_cnbaFound) {
    warn "stale Nix build artifacts found:"
    $_cnbaOutput | ForEach-Object { warn "  $_" }
    $exitCode = 1
    if ($FAIL_FAST) { exit $exitCode }
  } else {
    say "no stale Nix build artifacts found."
  }

# ---------------------------------------------------------------------------
# 9. Shell script validation tests
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Shell script validation tests ===" -f (++$_step))
say "skipping (bash-based test scripts — not available on Windows)."

# ---------------------------------------------------------------------------
# 10. CWD-independence tests
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] CWD-independence tests ===" -f (++$_step))
say "skipping (bash-based test scripts — not available on Windows)."

# ---------------------------------------------------------------------------
# 11. Nix search path tests
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Nix search path tests ===" -f (++$_step))
say "skipping (bash-based test scripts — not available on Windows)."

# ---------------------------------------------------------------------------
# 12. Port utility function tests
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Port utility function tests ===" -f (++$_step))
say "skipping (bash-based test scripts — not available on Windows)."

# ---------------------------------------------------------------------------
# 13. Lockfile validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Lockfile validation ===" -f (++$_step))


# Consistency and overlap checks (always run, even in path-scoped mode):
#  1. lockfile.json must exist.
#  2. No package should appear in multiple package-manager sections.
#     (Ollama is excluded because it uses a nested structure unrelated to
#      package versions.)
$_lfPath = Join-Path $RepoRoot "src\lockfiles\lockfile.json"
$_lf = $null
$_lfOverlapErrors = 0
if (-not (Test-Path $_lfPath)) {
  warn "lockfile.json not found at $_lfPath"
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
  $_lfOverlapErrors++
} else {
  $_lf = Get-Content $_lfPath -Raw | ConvertFrom-Json -AsHashtable
  # Known cross-section overlaps that are legitimate (same publisher.package ID
  # used for different products across package-manager sections).
  # Add new entries here with a brief justification comment.
  # astral-sh.ty: VS Code extension (vscode) vs CLI tool (winget) — different products
  $_lfOverlapExceptions = @('astral-sh.ty')
  $_pkgToSections = @{}
  foreach ($_section in $_lf.Keys) {
    if ($_section -eq 'ollama') { continue }
    if ($_lf[$_section] -is [hashtable]) {
      foreach ($_pkg in $_lf[$_section].Keys) {
        if ($_pkgToSections.ContainsKey($_pkg)) {
          $_pkgToSections[$_pkg] += ,$_section
        } else {
          $_pkgToSections[$_pkg] = @($_section)
        }
      }
    }
  }
  foreach ($_entry in $_pkgToSections.GetEnumerator()) {
    if ($_entry.Value.Count -gt 1 -and $_entry.Key -notin $_lfOverlapExceptions) {
      warn ("package '{0}' appears in both {1}" -f $_entry.Key, ($_entry.Value -join ', '))
      $_lfOverlapErrors++
    }
  }
}
if ($_lfOverlapErrors -gt 0) {
  warn ("lockfile.json consistency: {0} overlap issue(s)" -f $_lfOverlapErrors)
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
} else {
  say "lockfile.json consistency: no overlapping packages across sections"
}

# Lifecycle script allowlist validation (always run):
#  - lifecycle-allowlist.json must exist and be a valid JSON object.
#  - Each entry must have a non-empty justification string.
$_lfAlPath = Join-Path $RepoRoot "src\lockfiles\lifecycle-allowlist.json"
$_lfAlErrors = 0
if (-not (Test-Path $_lfAlPath)) {
  warn "lifecycle-allowlist.json not found at $_lfAlPath"
  $_lfAlErrors++
} else {
  $_lfAlRaw = Get-Content $_lfAlPath -Raw -ErrorAction Stop
  $_lfAl = $null
  try {
    $_lfAl = ConvertFrom-Json $_lfAlRaw -AsHashtable
  } catch {
    warn "lifecycle-allowlist.json is not valid JSON: $_($_.Exception.Message)"
    $_lfAlErrors++
  }
  if ($null -ne $_lfAl -and $_lfAl -isnot [hashtable]) {
    warn "lifecycle-allowlist.json must be a JSON object"
    $_lfAlErrors++
  } elseif ($null -ne $_lfAl) {
    foreach ($_entry in $_lfAl.GetEnumerator()) {
      if ($_entry.Value -isnot [string] -or [string]::IsNullOrEmpty($_entry.Value)) {
        warn "lifecycle-allowlist.json: '$_($_entry.Key)' has empty or non-string justification"
        $_lfAlErrors++
      }
    }
  }
}
if ($_lfAlErrors -gt 0) {
  warn "lifecycle-allowlist.json validation failed with $_lfAlErrors error(s)"
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
} else {
  $_lfAlCount = if ($null -ne $_lfAl -and $_lfAl -is [hashtable]) { $_lfAl.Count } else { 0 }
  say ("lifecycle-allowlist.json: valid (entry count: {0})" -f $_lfAlCount)
}

# Always-run: Lockfile section validation
if ($null -eq $_lf) {
    warn "lockfile.json could not be loaded — skipping section validation"
    $exitCode = 1
    if ($FAIL_FAST) { exit $exitCode }
  } else {
    $_lfErrors = 0

    # Check sections that must be non-empty
    foreach ($_section in @('scoop', 'cargo-binstall', 'bun', 'uv', 'rustup', 'pwsh')) {
      if (-not $_lf.ContainsKey($_section) -or $_lf[$_section].Count -eq 0) {
        warn "${_section}: empty or missing section"
        $_lfErrors++
      } else {
        foreach ($_entry in $_lf[$_section].GetEnumerator()) {
          if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
            warn "${_section}.$($_entry.Key): placeholder version ($($_entry.Value))"
            $_lfErrors++
          }
        }
      }
    }

    # winget: warn if empty
    if (-not $_lf.ContainsKey('winget')) {
      warn "winget: missing section"
      $_lfErrors++
    } elseif ($_lf.winget.Count -gt 0) {
      foreach ($_entry in $_lf.winget.GetEnumerator()) {
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
          warn "winget.$($_entry.Key): placeholder version ($($_entry.Value))"
          $_lfErrors++
        }
      }
    } else {
      say "warning: winget: empty section (not yet populated)"
    }

    # vscode: warn if empty
    if (-not $_lf.ContainsKey('vscode')) {
      warn "vscode: missing section"
      $_lfErrors++
    } elseif ($_lf.vscode.Count -gt 0) {
      foreach ($_entry in $_lf.vscode.GetEnumerator()) {
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
          warn "vscode.$($_entry.Key): placeholder version ($($_entry.Value))"
          $_lfErrors++
        }
      }
    } else {
      say "warning: vscode: empty section (not yet populated)"
    }

    # homebrew: must be non-empty
    if (-not $_lf.ContainsKey('homebrew') -or $_lf.homebrew.Count -eq 0) {
      warn "homebrew: empty or missing section"
      $_lfErrors++
    }

    # ollama: must have at least one profile with models
    if (-not $_lf.ContainsKey('ollama') -or $_lf.ollama.Count -eq 0) {
      warn "ollama: empty or missing section"
      $_lfErrors++
    } else {
      foreach ($_profile in $_lf.ollama.GetEnumerator()) {
        if ($_profile.Value.Count -eq 0) {
          warn "ollama.$_($_profile.Key): empty model list"
          $_lfErrors++
        } else {
          for ($_i = 0; $_i -lt $_profile.Value.Count; $_i++) {
            $_model = $_profile.Value[$_i]
            if ([string]::IsNullOrEmpty($_model.name) -or [string]::IsNullOrEmpty($_model.tag)) {
              warn "ollama.$_($_profile.Key)[$_i]: missing name or tag"
              $_lfErrors++
            }
          }
        }
      }
    }

    if ($_lfErrors -gt 0) {
      warn "lockfile.json validation failed with $_lfErrors error(s)"
      $exitCode = 1
      if ($FAIL_FAST) { exit $exitCode }
    } else {
      say "lockfile.json validation passed"
    }
  }

# ---------------------------------------------------------------------------
# 14. Locked DSC validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Locked DSC validation ===" -f (++$_step))
# Platform parallel: check.sh uses yq+jq pipeline (POSIX-native equivalent).
# Always-run: Locked DSC validation
$_dscSystemDir = Join-Path $RepoRoot 'src\hosts\Windows\system'
$_dscSystemPackages = Join-Path $RepoRoot 'src\hosts\Windows\system\packages.dsc.yml'
$_lockfilePath = Join-Path $RepoRoot 'src\lockfiles\lockfile.json'
$_lfErrors = 0

  # Helper: convert mixed PSCustomObject/hashtable/list trees to pure hashtable/array.
  function ConvertTo-HashtableDeep ($_obj) {
    if ($_obj -is [PSCustomObject]) {
      $_ht = [ordered] @{}
      $_obj.PSObject.Properties | ForEach-Object { $_ht[$_.Name] = ConvertTo-HashtableDeep $_.Value }
      return $_ht
    }
    if ($_obj -is [array] -or $_obj -is [System.Collections.IList]) { $_result = @(); foreach ($_item in $_obj) { $_result += ConvertTo-HashtableDeep $_item }; return ,$_result }
    if ($_obj -is [hashtable] -or $_obj -is [System.Collections.Specialized.OrderedDictionary]) {
      $_ht = @{}
      foreach ($_key in $_obj.Keys) { $_ht[$_key] = ConvertTo-HashtableDeep $_obj[$_key] }
      return $_ht
    }
    return $_obj
  }

  # Helper: normalize resources (which may arrive in columnar OrderedDictionary/hashtable
  # format from powershell-yaml on Windows CI) to a flat array of resource items.
  function ConvertTo-ResourceArray ($_resources) {
    if ($null -eq $_resources) { return ,@() }
    if ($_resources -is [array] -or $_resources -is [System.Collections.IList]) { return ,@($_resources) }
    if ($_resources -is [System.Collections.IDictionary]) {
      $_keys = @($_resources.Keys)
      if ($_keys.Count -gt 0) {
        $_firstVal = $_resources[$_keys[0]]
        if ($null -ne $_firstVal -and ($_firstVal -is [array] -or $_firstVal -is [System.Collections.IList])) {
          # Columnar format — unpivot into individual items.
          $_count = $_firstVal.Count
          $_result = @()
          for ($_i = 0; $_i -lt $_count; $_i++) {
            $_item = @{}
            foreach ($_key in $_keys) {
              $_val = $_resources[$_key]
              if ($null -ne $_val -and ($_val -is [array] -or $_val -is [System.Collections.IList]) -and $_i -lt $_val.Count) {
                $_item[$_key] = $_val[$_i]
              }
            }
            $_result += $_item
          }
          return ,$_result
        }
      }
      # Single resource item (not columnar).
      return ,@($_resources)
    }
    return ,@($_resources)
  }

  # Generate locked DSC in-memory from all system DSC files + lockfile.
  $_lockfileData = Get-Content $_lockfilePath -Raw | ConvertFrom-Json -AsHashtable
  # Read all system DSC files (sorted by name), excluding packages.dsc.yml.
  $_dscSystemFiles = Get-ChildItem (Join-Path $_dscSystemDir '*.dsc.yml') | Where-Object { $_.Name -ne 'packages.dsc.yml' } | Sort-Object Name
  # Initialize DSC from the first file's structure.
  $_dscYaml = Get-Content $_dscSystemFiles[0].FullName -Raw
  $_dsc = ConvertTo-HashtableDeep ($_dscYaml | ConvertFrom-Yaml)
  $_dsc.properties.resources = ConvertTo-ResourceArray $_dsc.properties.resources
  # Merge resources from remaining system DSC files.
  foreach ($_file in $_dscSystemFiles[1..($_dscSystemFiles.Count - 1)]) {
    $_fileYaml = Get-Content $_file.FullName -Raw
    $_fileDsc = ConvertTo-HashtableDeep ($_fileYaml | ConvertFrom-Yaml)
    $_fileDsc.properties.resources = ConvertTo-ResourceArray $_fileDsc.properties.resources
    $_dsc.properties.resources += $_fileDsc.properties.resources
  }
  # Merge package resources from system/packages.dsc.yml into the main DSC tree.
  $_dscPkgYaml = Get-Content $_dscSystemPackages -Raw
  $_dscPkg = ConvertTo-HashtableDeep ($_dscPkgYaml | ConvertFrom-Yaml)
  $_dscPkg.properties.resources = ConvertTo-ResourceArray $_dscPkg.properties.resources
  $_dsc.properties.resources += $_dscPkg.properties.resources

  foreach ($_resource in $_dsc.properties.resources) {
    if ($_resource.resource -eq 'Microsoft.WinGet.Client/Package' -and $_resource.settings.source -eq 'winget') {
      $_id = $_resource.settings.id
      if ($_lockfileData.winget.ContainsKey($_id) -and $_lockfileData.winget[$_id]) {
        # Use Add-Member instead of direct assignment so this works on both
        # PSCustomObject and hashtable under Set-StrictMode -Version Latest.
        $_resource.settings | Add-Member -NotePropertyName version -NotePropertyValue $_lockfileData.winget[$_id] -Force
      }
    }
  }

  # Validate generated pins match lockfile entries.
  foreach ($_resource in $_dsc.properties.resources) {
    $_hasVer = $_resource.settings.PSObject.Properties.Name -contains 'version'
    if ($_resource.resource -eq 'Microsoft.WinGet.Client/Package' `
        -and $_resource.settings.source -eq 'winget' `
        -and $_hasVer) {
      $_id = $_resource.settings.id
      $_pinnedVer = $_resource.settings.version
      $_lfVer = if ($_lockfileData.winget.ContainsKey($_id)) { $_lockfileData.winget[$_id] } else { '' }

      if ([string]::IsNullOrEmpty($_lfVer)) {
        warn "system DSC files: $_id has version $_pinnedVer but no lockfile entry"
        $_lfErrors++
      } elseif ($_pinnedVer -ne $_lfVer) {
        warn "system DSC files: $_id pinned $_pinnedVer but lockfile has $_lfVer"
        $_lfErrors++
      }
    }
  }

  # Check for lockfile entries missing version pins in generated output.
  foreach ($_entry in $_lockfileData.winget.GetEnumerator()) {
    $_id = $_entry.Key
    $_lfVer = $_entry.Value
    $_foundPin = $false
    foreach ($_resource in $_dsc.properties.resources) {
      $_hasVer = $_resource.settings.PSObject.Properties.Name -contains 'version'
      if ($_resource.resource -eq 'Microsoft.WinGet.Client/Package' `
          -and $_resource.settings.source -eq 'winget' `
          -and $_resource.settings.id -eq $_id `
          -and $_hasVer) {
        $_foundPin = $true
        break
      }
    }
    if (-not $_foundPin) {
      warn "$_id ($_lfVer) is in lockfile but missing version pin after generation"
      $_lfErrors++
    }
  }

  if ($_lfErrors -gt 0) {
    warn "locked DSC validation failed with $_lfErrors error(s)"
    $exitCode = 1
    if ($FAIL_FAST) { exit $exitCode }
  } else {
    say "locked DSC validation passed"
  }

# ---------------------------------------------------------------------------
# 15. Schema validation (JSON/YAML)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Schema validation (JSON/YAML) ===" -f (++$_step))
$_jsonschemaErrors = 0
if ($HAS_ARGS) {
  # Validate only explicitly provided files
  foreach ($_sf in $positionalArgs) {
    if ($_sf -like '*.json') {
      $_schema = try { (Get-Content $_sf -Raw | ConvertFrom-Json -AsHashtable)['$schema'] } catch { $null }
      if ($_schema) {
        if ($_schema -match '^\.') {
          $_schemafile = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $_sf -Parent) $_schema))
        } else {
          $_schemafile = $_schema
        }
        check-jsonschema --schemafile $_schemafile $_sf 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
      }
    } elseif ($_sf -like '*.yml' -or $_sf -like '*.yaml') {
      $_schema = try {
        $_content = Get-Content $_sf -Raw
        ($_content | ConvertFrom-Yaml)['$schema']
      } catch { $null }
      if ($_schema) {
        if ($_schema -match '^\.') {
          $_schemafile = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $_sf) $_schema))
        } else {
          $_schemafile = $_schema
        }
        check-jsonschema --schemafile $_schemafile $_sf 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
      }
    }
  }
} else {
  # JSON files with inline $schema — auto-discover and validate
  Get-ChildItem -Recurse -Path "$RepoRoot/src" -Filter '*.json' | Where-Object {
    $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.Name -notlike '*.schema.json'
  } | ForEach-Object {
    $_schema = try { (Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable)['$schema'] } catch { $null }
    if ($_schema) {
      if ($_schema -match '^\.') {
        $_schemafile = [System.IO.Path]::GetFullPath((Join-Path $_.DirectoryName $_schema))
      } else {
        $_schemafile = $_schema
      }
      check-jsonschema --schemafile $_schemafile $_.FullName 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
    }
  }
  # YAML files with inline $schema — auto-discover and validate
  Get-ChildItem -Recurse -Path $RepoRoot -Include '*.yml','*.yaml' | Where-Object {
    $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.FullName -notmatch '[/\\]secrets[/\\]'
  } | ForEach-Object {
    $_schema = try {
      $_content = Get-Content $_.FullName -Raw
      ($_content | ConvertFrom-Yaml)['$schema']
    } catch { $null }
    if ($_schema) {
      if ($_schema -match '^\.') {
        $_schemafile = [System.IO.Path]::GetFullPath((Join-Path $_.DirectoryName $_schema))
      } else {
        $_schemafile = $_schema
      }
      check-jsonschema --schemafile $_schemafile $_.FullName 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
    }
  }
}
# GitHub schema validation (complements existing prek hooks — CI enforcement) — always-run
$_ghWorkflows = Join-Path $RepoRoot '.github\workflows\*.yml'
check-jsonschema --builtin-schema vendor.github-workflows $_ghWorkflows 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
$_dependabot = Join-Path $RepoRoot '.github\dependabot.yml'
if (Test-Path $_dependabot) {
  check-jsonschema --builtin-schema vendor.dependabot $_dependabot 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
}
if ($_jsonschemaErrors -gt 0) {
  warn "schema validation failed with $_jsonschemaErrors error(s)"
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
}
say "schema validation passed."

# ---------------------------------------------------------------------------
# 16. Service registry validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Service registry validation ===" -f (++$_step))
# Always-run: Service registry validation
$_svcJson = Join-Path $RepoRoot "src\modules\services.json"
$_svcErrors = 0

if (-not (Test-Path $_svcJson)) {
    warn "services.json not found at $_svcJson"
    $_svcErrors++
  } else {
    $_svc = Get-Content $_svcJson -Raw | ConvertFrom-Json -AsHashtable

    foreach ($_svcName in $_svc.Keys) {
      if ($_svcName -like '$*') { continue }
      $_entry = $_svc[$_svcName]
      if ($_entry -isnot [hashtable]) { continue }
      if (-not $_entry.ContainsKey('displayName') -or [string]::IsNullOrEmpty($_entry.displayName)) {
        warn "services.json: '$_svcName' missing displayName"
        $_svcErrors++
      }
      if (-not $_entry.ContainsKey('platforms') -or $_entry.platforms.Count -eq 0) {
        warn "services.json: '$_svcName' missing or empty platforms"
        $_svcErrors++
      } else {
        foreach ($_plat in $_entry.platforms.Keys) {
          $_pEntry = $_entry.platforms[$_plat]
          $_type = $_pEntry.type
          if ($_type -notin @('launchctl', 'systemctl', 'native', 'schtask', 'omitted')) {
            warn "services.json: '$_svcName' platform '$_plat' has invalid type '$_type'"
            $_svcErrors++
          }
          $_hasRequired = switch ($_type) {
            'launchctl' { -not [string]::IsNullOrEmpty($_pEntry.service) }
            'systemctl' { -not [string]::IsNullOrEmpty($_pEntry.service) }
            'native'    { -not [string]::IsNullOrEmpty($_pEntry.service) }
            'schtask'   { -not [string]::IsNullOrEmpty($_pEntry.taskPath) }
            'omitted'   { -not [string]::IsNullOrEmpty($_pEntry.justification) }
            default     { $false }
          }
          if (-not $_hasRequired) {
            warn "services.json: '$_svcName' platform '$_plat' missing required fields for type '$_type'"
            $_svcErrors++
          }
        }
      }
    }
  }

  if ($_svcErrors -gt 0) {
    warn "services.json validation failed with $_svcErrors error(s)"
    $exitCode = 1
    if ($FAIL_FAST) { exit $exitCode }
  } else {
    # Validate user-scoped platform entries have justification.
    foreach ($_svcName in $_svc.Keys) {
      if ($_svcName -like '$*') { continue }
      $_entry = $_svc[$_svcName]
      if ($_entry -isnot [hashtable]) { continue }
      if ($_entry.ContainsKey('platforms')) {
        foreach ($_plat in $_entry.platforms.Keys) {
          $_pEntry = $_entry.platforms[$_plat]
          $_domainScope = if ($_pEntry.ContainsKey('domain')) { $_pEntry.domain } elseif ($_pEntry.ContainsKey('scope')) { $_pEntry.scope } else { $null }
          $_hasJustification = $_pEntry.ContainsKey('justification') -and -not [string]::IsNullOrEmpty($_pEntry.justification)
          if ($_domainScope -eq 'user' -and -not $_hasJustification) {
            warn "services.json: '$_svcName' platform '$_plat' is user-scoped but missing justification"
            $_svcErrors++
          }
        }
      }
    }

    # Validate that service names in users.json services blocks exist in services.json.
    $_usersJson = Join-Path $RepoRoot "src\modules\users.json"
    if (Test-Path $_usersJson) {
      $_users = Get-Content $_usersJson -Raw | ConvertFrom-Json -AsHashtable
      foreach ($_username in $_users.Keys) {
        $_userEntry = $_users[$_username]
        if ($_userEntry.ContainsKey('services')) {
          foreach ($_svcKey in $_userEntry.services.Keys) {
            if (-not $_svc.ContainsKey($_svcKey)) {
              warn "${_usersJson}: user '$_username' references unknown service '$_svcKey'"
              $_svcErrors++
            }
          }
        }
      }
    }

    # Windows users.json
    $_winUsersJson = Join-Path $RepoRoot "src\hosts\Windows\users.json"
    if (Test-Path $_winUsersJson) {
      $_winUsers = (Get-Content $_winUsersJson -Raw | ConvertFrom-Json -AsHashtable).users
      if ($_winUsers) {
        foreach ($_username in $_winUsers.Keys) {
          $_userEntry = $_winUsers[$_username]
          if ($_userEntry.ContainsKey('services')) {
            foreach ($_svcKey in $_userEntry.services.Keys) {
              if (-not $_svc.ContainsKey($_svcKey)) {
                warn "${_winUsersJson}: user '$_username' references unknown service '$_svcKey'"
                $_svcErrors++
              }
            }
          }
        }
      }
    }

    if ($_svcErrors -gt 0) {
      warn "services.json validation failed with $_svcErrors error(s)"
      $exitCode = 1
      if ($FAIL_FAST) { exit $exitCode }
    }
    say "services.json validation passed"
  }

# ---------------------------------------------------------------------------
# 17. YAML validation and linting
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] YAML validation and linting ===" -f (++$_step))
$_yamlErrors = 0
$_yamlFiles = @()
if ($HAS_ARGS) {
  $_yamlFiles = $positionalArgs | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' }
} else {
  $_yamlFiles = $script:CachedYamlFiles |
    Where-Object { $_.FullName -notmatch '[/\\]secrets[/\\]' } |
    ForEach-Object { $_.FullName }
}
foreach ($_yf in $_yamlFiles) {
  # Validate
  try {
    $_content = Get-Content $_yf -Raw -ErrorAction Stop
    $null = $_content | ConvertFrom-Yaml -ErrorAction Stop
  } catch {
    warn "$($_yf): invalid YAML"
    $_yamlErrors++
  }
  # Lint
  yamllint --strict $_yf 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    warn "$($_yf): yamllint violations"
    $_yamlErrors++
  }
}
if ($_yamlErrors -gt 0) {
  warn "YAML validation/lint failed with $_yamlErrors error(s)"
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
}
say "YAML validation and linting passed."

# ---------------------------------------------------------------------------
# 19. Package manager usage enforcement
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Package manager usage enforcement ===" -f (++$_step))
# Always-run: Package manager usage enforcement
$_violations = 0
  # Ban bare pip install and npm install — these bypass the lockfile.
  # uv pip install is allowed.  Exclude self-references.
  $_pipViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$RepoRoot\scripts","$RepoRoot\src","$RepoRoot\tests" `
      -Include *.sh,*.ps1,*.nix `
      -Exclude check.sh,check.ps1,shell.nix `
      | ForEach-Object { $_.FullName }
    ) -Pattern '(^|[^a-z])pip install([^-]|$)' `
    | Where-Object { $_.Line -notmatch 'uv pip install' }
  if ($_pipViolations) {
    warn "bare pip install detected (use uv pip install instead)"
    $_violations++
  }
  $_npmViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$RepoRoot\scripts","$RepoRoot\src","$RepoRoot\tests" `
      -Include *.sh,*.ps1,*.nix `
      -Exclude check.sh,check.ps1,shell.nix `
      | ForEach-Object { $_.FullName }
    ) -Pattern '(^|[^a-z])npm install([^-]|$)'
  if ($_npmViolations) {
    warn "bare npm install detected (use bun or nix instead)"
    $_violations++
  }
  if ($_violations -gt 0) {
    $exitCode = 1
    if ($FAIL_FAST) { exit $exitCode }
  } else {
    say "no package manager violations found."
  }

# ---------------------------------------------------------------------------
# 20. Undocumented error suppression check
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Undocumented error suppression check ===" -f (++$_step))

$_undocSuppViolations = @()

function Test-Suppressed {
  param([string]$CheckId, [string]$Path, [int]$LineNumber)
  $line = Get-Content -Path $Path | Select-Object -Index ($LineNumber - 1)
  if ($line -match "# check-suppress:$CheckId[\s:]") { return $true }
  if ($LineNumber -gt 1) {
    $prevLine = Get-Content -Path $Path | Select-Object -Index ($LineNumber - 2)
    if ($prevLine -match "# check-suppress:$CheckId[\s:]") { return $true }
  }
  return $false
}

function Get-UndocSuppViolation {
  param([string]$_uPattern, [string]$_uLabel, [switch]$_uIsRegex, [string[]]$_uFiles)
  $_uResult = @()
  if ($_uFiles.Count -eq 0) { return $_uResult }
  try {
    $_uSelParams = @{ Path = $_uFiles; AllMatches = $true }
    if ($_uIsRegex) { $_uSelParams['Pattern'] = $_uPattern } else { $_uSelParams['SimpleMatch'] = $_uPattern }
    $_uMatches = Select-String @_uSelParams
    foreach ($_um in $_uMatches) {
      # Skip comment-only lines (PowerShell #, bash #, Nix #)
      if ($_um.Line -match '^\s*#') { continue }
      # Skip lines with inline # undoc-supp: comment (deprecated format)
      if ($_um.Line -match '# undoc-supp:') { continue }
      # Skip lines with # check-suppress:suppression_doc: inline (new format)
      if (Test-Suppressed -CheckId 'suppression_doc' -Path $_um.Path -LineNumber $_um.LineNumber) { continue }
      # Skip if preceding line has suppression comment (old or new format)
      if ($_um.LineNumber -gt 1) {
        $_uPrevLine = Get-Content -Path $_um.Path | Select-Object -Index ($_um.LineNumber - 2)
        if ($_uPrevLine -match '# undoc-supp:|# check-suppress:suppression_doc[\s:]') { continue }
      }
      $_uResult += "$($_um.Path):$($_um.LineNumber) ($_uLabel)"
    }
  } catch {
    Write-Warning "Error scanning for $_uLabel`: $_"
  }
  return $_uResult
}

if ($HAS_ARGS) {
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern '|| true' -Label '|| true' -Files ($SH_FILES + $NIX_FILES)
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real suppression operator.
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern '2>$null' -Label '2>$null' -Files $PS1_FILES
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real suppression operator.
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern '-ErrorAction SilentlyContinue' -Label '-ErrorAction SilentlyContinue' -Files $PS1_FILES
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real suppression operator.
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern 'catch\s*\{\s*\}' -Label 'empty catch {}' -IsRegex -Files $PS1_FILES
} else {
  $_uAllShNix = @(
    Get-ChildItem -Recurse -Path $RepoRoot -Include '*.sh','*.nix' |
      Where-Object { $_.FullName -notmatch '[\\\\/]vendor[\\\\/]' } |
      ForEach-Object { $_.FullName }
  )
  $_uAllPs1 = @(
    Get-ChildItem -Recurse -Path $RepoRoot -Include '*.ps1' |
      Where-Object { $_.FullName -notmatch '[\\\\/]vendor[\\\\/]' } |
      ForEach-Object { $_.FullName }
  )
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern '|| true' -Label '|| true' -Files $_uAllShNix
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real suppression operator.
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern '2>$null' -Label '2>$null' -Files $_uAllPs1
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real suppression operator.
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern '-ErrorAction SilentlyContinue' -Label '-ErrorAction SilentlyContinue' -Files $_uAllPs1
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real suppression operator.
  $_undocSuppViolations += Get-UndocSuppViolation -Pattern 'catch\s*\{\s*\}' -Label 'empty catch {}' -IsRegex -Files $_uAllPs1
}

if ($_undocSuppViolations.Count -gt 0) {
  foreach ($_uv in ($_undocSuppViolations | Sort-Object -Unique)) {
    warn $_uv
  }
  warn ("undocumented error suppression check failed with {0} violation(s)" -f $_undocSuppViolations.Count)
  say "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
} else {
  say "no undocumented error suppressions found."
}
if ($FAIL_FAST -and $exitCode -ne 0) { exit $exitCode }

# ---------------------------------------------------------------------------
# 21. Online determinism checks (--verify mode only)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Online determinism checks (--verify) ===" -f (++$_step))
if ($VERIFY) {
  & "$PSScriptRoot\bump-lockfile.ps1" -Verify
  if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
  if ($FAIL_FAST -and $exitCode -ne 0) { exit $exitCode }
  if ($LASTEXITCODE -eq 0) {
    say "online determinism checks passed."
  }
} else {
  say "skipping (use --verify to run online determinism checks)."
}

# ---------------------------------------------------------------------------
# 22. Config method compliance
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Config method compliance ===" -f (++$_step))
$_cfgDir = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs"
$_cfgErrors = 0

# Always-run: Config method compliance
$_cfgFiles = Get-ChildItem -Path $_cfgDir -Recurse -File

  # Build source file list once for efficiency
  $_srcFiles = Get-ChildItem -Path (Join-Path $RepoRoot "src") -Recurse -Include '*.nix', '*.ps1', '*.sh' |
    Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' -and $_.FullName -notmatch '[\\/]configs[\\/]' }

  foreach ($_cfgFile in $_cfgFiles) {
    $_basename = $_cfgFile.Name

    # Skip infrastructure files and Nix modules inside configs/
    if ($_basename -in '.gitkeep', '.gitignore') { continue }
    if ($_basename -like '*.schema.json') { continue }
    if ($_basename -eq 'qtpass.nix') { continue }

    # Skip agent customization files (consumed as a directory via Method 4)
    $_relPath = $_cfgFile.FullName.Substring($_cfgDir.Length + 1) -replace '\\', '/'
    if ($_relPath -like 'agents/*') { continue }

    # Search using relative path first (avoids false matches on generic names like config.toml)
    $_refs = @($_srcFiles | Select-String -Pattern ([regex]::Escape($_relPath)) -SimpleMatch)

    if ($_refs.Count -eq 0) {
      # Fall back to basename
      $_refs = @($_srcFiles | Select-String -Pattern ([regex]::Escape($_basename)) -SimpleMatch)
    }

    if ($_refs.Count -eq 0) {
      warn "$_relPath : no references found in src/ (excluding configs/) — orphaned config?"
      $_cfgErrors++
    } else {
      $_hasMethod = $false
      foreach ($_ref in $_refs) {
        if ($_ref.Line -match '# Method') {
          $_hasMethod = $true
          break
        }
        # Check preceding line
        if ($_ref.LineNumber -gt 1) {
          $_prevLines = Get-Content -Path $_ref.Path -TotalCount $_ref.LineNumber
          if ($_prevLines.Count -ge 2) {
            $_prevLine = $_prevLines[$_prevLines.Count - 2]
            if ($_prevLine -match '# Method') {
              $_hasMethod = $true
              break
            }
          }
        }
      }
      if (-not $_hasMethod) {
        warn "$_relPath : referenced but no '# Method N' comment found on or before reference lines"
        $_cfgErrors++
      }
    }
  }

if ($_cfgErrors -gt 0) {
  warn ("config method compliance check failed with {0} error(s)" -f $_cfgErrors)
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
} else {
  say "config method compliance passed."
}
if ($FAIL_FAST -and $exitCode -ne 0) { exit $exitCode }

# ---------------------------------------------------------------------------
# 23. Activation script token placeholder in comment check
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Activation script token placeholder in comment check ===" -f (++$_step))
$_actPattern = '^\s*#.*__[A-Z][A-Z_]*__'
$_actViolations = @()
if ($HAS_ARGS) {
  foreach ($_f in $positionalArgs) {
    if ($_f -like '*.sh' -or $_f -like '*.zsh') {
      $_actViolations += Select-String -Path $_f -Pattern $_actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
    }
  }
} else {
  $_actFiles = Get-ChildItem -Recurse -Path (Join-Path $RepoRoot "src\scripts") -Include '*.sh','*.zsh' | ForEach-Object { $_.FullName }
  $_actViolations += Select-String -Path $_actFiles -Pattern $_actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
}
if ($_actViolations.Count -gt 0) {
  foreach ($_av in ($_actViolations | Sort-Object -Unique)) { warn $_av }
  warn "token placeholder strings found in script comments"
  $exitCode = 1
  if ($FAIL_FAST) { exit $exitCode }
} else {
  say "no token placeholder strings in script comments."
}

# ---------------------------------------------------------------------------
if ($exitCode -ne 0) {
  warn "some checks failed with exit code $exitCode"
  exit $exitCode
}
say "all checks passed."
