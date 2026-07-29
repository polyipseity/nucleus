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
#   1. Code formatting and linting (treefmt equivalent — yamllint on Windows)
#   2. PowerShell lint (PSScriptAnalyzer with check settings, slow rules excluded)
#   3. Packer template validation
#
# Nix checks (4-6, stubs on Windows):
#   4. Nix flake evaluation (stub)
#   5. Nix lint (nixf-tidy) (stub)
#   6. Stale Nix build artifact check
#
# Test suites (7-10, stubs on Windows):
#   7. Shell script validation tests (stub)
#   8. CWD-independence tests (stub)
#   9. Nix search path tests (stub)
#  10. Port utility function tests (stub)
#
# Data integrity (11-14):
#  11. Lockfile validation
#  12. Locked DSC validation
#  13. Schema validation (JSON/YAML)
#  14. Service registry validation
#
# Policy/verification (15-20):
#  15. YAML structural validation
#  16. Package manager usage enforcement
#  17. Undocumented error suppression check
#  18. Online determinism checks (--verify mode only)
#  19. Config method compliance
#  20. Activation script token placeholder in comment check
#
# Cross-platform correspondence:
#  POSIX (check.sh step 1 via treefmt)  →  Windows (check.ps1 step 1, individual tools)
#    treefmt wraps:
#      nixfmt                              —   Nix-only; not on Windows
#      deadnix                             —   Nix-only; not on Windows
#      yamllint                            →   yamllint (runs individually)
#      shellcheck                          —   POSIX-only; not on Windows
#  See scripts/check.sh header comment for the POSIX counterpart. The suffix
#  "(treefmt equivalent)" in step names is the bidirectional anchor — a reader
#  seeing it in check.ps1 knows to check check.sh step 1 for the full treefmt
#  multiplexer, and vice versa.
#
# Mode taxonomy:
#   Always-run (no HAS_ARGS guard — run in both --full and --scoped):
#     - Stale Nix build artifact check        (step 6)
#     - Lockfile section validation           (step 11)
#     - Locked DSC validation                 (step 12)
#     - Service registry validation           (step 14)
#     - Package manager usage enforcement     (step 16)
#     - Config method compliance              (step 19)
#   Path-scopable (accept file filtering in both modes):
#     - Code formatting and linting (treefmt equivalent)  (step 1)
#     - PowerShell lint          (step 2)
#     - Packer template validation            (step 3)
#     - Schema validation                     (step 13)
#     - YAML structural validation            (step 15)
#     - Undocumented error suppression        (step 17)
#     - Activation script token placeholder   (step 20)
#
# Note: Steps 4-5, 7-10 are stubs on Windows (Nix toolchain or bash not available).
#
# Output conventions:
#   Three-tier messaging: say() for info/success/skip, warn() for non-fatal
#   warnings, error() for failures — all to stdout.
#   This differs from check.sh, which routes warn/error to stderr — the
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
# Step 1 runs yamllint on Windows (corresponds to treefmt on POSIX — see Cross-platform correspondence above).
# Steps 4-5, 7-10 are stubs (require Nix or bash — not available on Windows).
# Step 18 only runs with the --verify flag.
#
# Prerequisites:
#   - check-jsonschema (pip install check-jsonschema) for schema validation
#   - Ensure-Tool module (imported via pre-flight block) for tool validation
#   - powershell-yaml module (Install-Module powershell-yaml -Scope CurrentUser)
#     is required for locked DSC validation.
#   - yamllint (pip install yamllint) for YAML linting (step 1, treefmt equivalent on Windows)
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
# All three (say/warn/error) route to stdout (PowerShell convention);
# compare with check.sh which routes warn/error to stderr (POSIX convention).
function say { Write-Output "check: $args" }
function warn { Write-Output "check: warning: $args" }
function error { Write-Output "check: error: $args" }

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

# Wave parallelism infrastructure
$script:WaveTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$null = New-Item -ItemType Directory -Path $script:WaveTmpDir -Force
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
  if (Test-Path $script:WaveTmpDir) { Remove-Item -Recurse -Force $script:WaveTmpDir }
} | Out-Null

$script:parallelJobs = [Environment]::ProcessorCount
$script:runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $script:parallelJobs)
$script:runspacePool.Open()
$script:runspaceTasks = [System.Collections.Generic.List[hashtable]]::new()

function Add-RunspaceTask {
    param(
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList
    )
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $script:runspacePool
    $null = $ps.AddScript($ScriptBlock.ToString()).AddArguments($ArgumentList)
    $handle = $ps.BeginInvoke()
    $script:runspaceTasks.Add(@{PS = $ps; Handle = $handle})
}

$_step = 0

# Pre-flight tool availability checks.
# All tools listed in Prerequisites must be present. Missing tools produce
# an immediate hard failure — run bootstrap or nucleus-apply to install them.
$modulesPath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules'
Import-Module (Join-Path $modulesPath 'Ensure-Tool.psm1') -Force
Ensure-Tool -Name 'powershell-yaml' -Type 'Module' -InstallCommand "Install-Module powershell-yaml -Scope CurrentUser -Force"
Ensure-Tool -Name 'packer' -Type 'Command' -InstallCommand "winget install Hashicorp.Packer"
Ensure-Tool -Name 'check-jsonschema' -Type 'Command' -InstallCommand 'pip install check-jsonschema'
Ensure-Tool -Name 'yamllint' -Type 'Command' -InstallCommand 'pip install yamllint'
# yamllint is the Windows-available tool from the treefmt multiplexer (check.sh step 1).
# treefmt is POSIX-native and not available on Windows. nixfmt, deadnix, and shellcheck
# (the other treefmt-wrapped tools) are also Nix/POSIX-only.

# ---------------------------------------------------------------------------
# 1. Code formatting and linting (treefmt equivalent) — yamllint on Windows (treefmt correspondence group)
# On POSIX, this check runs via `treefmt --fail-on-change` (check.sh step 1) which wraps
# nixfmt, deadnix, yamllint, and shellcheck. On Windows, treefmt is unavailable, so
# yamllint runs individually. See scripts/check.sh header comment for the POSIX counterpart.
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Code formatting and linting (treefmt equivalent) ===" -f (++$_step))
"Code formatting and linting (treefmt equivalent)" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $HAS_ARGS, $positionalArgs, $RepoRoot, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $_yamlFiles = @()
  if ($HAS_ARGS) {
    $_yamlFiles = $positionalArgs | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' }
  } else {
    $_yamlFiles = Get-ChildItem -Recurse -Path $RepoRoot -Include '*.yml','*.yaml' |
      Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.FullName -notmatch '[/\\]secrets[/\\]' } |
      Sort-Object FullName |
      ForEach-Object { $_.FullName }
  }
  if ($_yamlFiles.Count -gt 0) {
    $_ylExit = 0
    foreach ($_yf in $_yamlFiles) {
      yamllint $_yf 2>&1 | ForEach-Object { Write-Output "[Step $_step] $_" }
      if ($LASTEXITCODE -ne 0) { $_ylExit = $LASTEXITCODE }
    }
    if ($_ylExit -ne 0) {
      error "yamllint found issues in YAML files."
      $_ylExit | Out-File -FilePath (Join-Path $WaveTmpDir "step-1.exit") -NoNewline
    } else {
      say "yamllint passed."
    }
  } else {
    say "skipping (no YAML files to check)."
    0 | Out-File -FilePath (Join-Path $WaveTmpDir "step-1.exit") -NoNewline
  }
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-1.time") -NoNewline
} -ArgumentList $_step, $HAS_ARGS, $positionalArgs, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 2. PowerShell lint
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] PowerShell lint ===" -f (++$_step))
"PowerShell lint" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $PS1_FILES, $RepoRoot, $HAS_ARGS, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function warn { Write-Output "[Step $_step] warning: $args" }
  $null = $_step
  $_ps1Files = $PS1_FILES
  if ($_ps1Files.Count -gt 0) {
    & "$RepoRoot\scripts\check-pwsh.ps1" -Settings "$RepoRoot\scripts\PSScriptAnalyzerSettings.check.psd1" -Scoped -Paths $_ps1Files
  } elseif (-not $HAS_ARGS) {
    & "$RepoRoot\scripts\check-pwsh.ps1" -Settings "$RepoRoot\scripts\PSScriptAnalyzerSettings.check.psd1"
  } else {
    say "skipping (no PowerShell scripts to check)."
  }
  $_stepExit = $LASTEXITCODE
  $_stepExit | Out-File -FilePath (Join-Path $WaveTmpDir "step-2.exit") -NoNewline
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-2.time") -NoNewline
} -ArgumentList $_step, $PS1_FILES, $RepoRoot, $HAS_ARGS, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 3. Packer template validation
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Packer template validation ===" -f (++$_step))
"Packer template validation" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $PKR_FILES, $RepoRoot, $HAS_ARGS, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function warn { Write-Output "[Step $_step] warning: $args" }
  $null = $_step
  $_pkrFiles = $PKR_FILES
  if ($_pkrFiles.Count -gt 0) {
    & "$RepoRoot\scripts\check-packer.ps1" $_pkrFiles
  } elseif (-not $HAS_ARGS) {
    & "$RepoRoot\scripts\check-packer.ps1"
  } else {
    say "skipping (no Packer templates to check)."
  }
  $_stepExit = $LASTEXITCODE
  $_stepExit | Out-File -FilePath (Join-Path $WaveTmpDir "step-3.exit") -NoNewline
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-3.time") -NoNewline
} -ArgumentList $_step, $PKR_FILES, $RepoRoot, $HAS_ARGS, $script:WaveTmpDir, $_stepStartTicks



# ---------------------------------------------------------------------------
# 4. Nix flake evaluation
# ---------------------------------------------------------------------------
$_sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output ("`n=== [{0}] Nix flake evaluation ===" -f (++$_step))
"Nix flake evaluation" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
say "skipping (requires Nix toolchain — not available on Windows)."
0 | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-4.exit") -NoNewline
$_sw.Stop()
$_sw.ElapsedMilliseconds | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-4.time") -NoNewline

# ---------------------------------------------------------------------------
# 5. Nix lint (nixf-tidy)
# ---------------------------------------------------------------------------
$_sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output ("`n=== [{0}] Nix lint (nixf-tidy) ===" -f (++$_step))
"Nix lint (nixf-tidy)" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
say "skipping (requires Nix toolchain — not available on Windows)."
0 | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-5.exit") -NoNewline
$_sw.Stop()
$_sw.ElapsedMilliseconds | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-5.time") -NoNewline

# ---------------------------------------------------------------------------
# 6. Stale Nix build artifact check
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Stale Nix build artifact check ===" -f (++$_step))
"Stale Nix build artifact check" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
  # Always-run: Stale Nix build artifact check
  $_cnbaOutput = & "$RepoRoot\scripts\cleanup-nix.ps1" -WhatIf 2>&1
  $_cnbaFound = $_cnbaOutput | Select-String -Pattern 'would remove stale Nix build symlink'
  if ($_cnbaFound) {
    error "stale Nix build artifacts found:"
    $_cnbaOutput | ForEach-Object { error "  $_" }
    1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-6.exit") -NoNewline
  } else {
    say "no stale Nix build artifacts found."
  }
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-6.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 7. Shell script validation tests
# ---------------------------------------------------------------------------
$_sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output ("`n=== [{0}] Shell script validation tests ===" -f (++$_step))
"Shell script validation tests" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
say "skipping (bash-based test scripts — not available on Windows)."
0 | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-7.exit") -NoNewline
$_sw.Stop()
$_sw.ElapsedMilliseconds | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-7.time") -NoNewline

# ---------------------------------------------------------------------------
# 8. CWD-independence tests
# ---------------------------------------------------------------------------
$_sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output ("`n=== [{0}] CWD-independence tests ===" -f (++$_step))
"CWD-independence tests" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
say "skipping (bash-based test scripts — not available on Windows)."
0 | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-8.exit") -NoNewline
$_sw.Stop()
$_sw.ElapsedMilliseconds | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-8.time") -NoNewline

# ---------------------------------------------------------------------------
# 9. Nix search path tests
# ---------------------------------------------------------------------------
$_sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output ("`n=== [{0}] Nix search path tests ===" -f (++$_step))
"Nix search path tests" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
say "skipping (bash-based test scripts — not available on Windows)."
0 | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-9.exit") -NoNewline
$_sw.Stop()
$_sw.ElapsedMilliseconds | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-9.time") -NoNewline

# ---------------------------------------------------------------------------
# 10. Port utility function tests
# ---------------------------------------------------------------------------
$_sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output ("`n=== [{0}] Port utility function tests ===" -f (++$_step))
"Port utility function tests" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
say "skipping (bash-based test scripts — not available on Windows)."
0 | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-10.exit") -NoNewline
$_sw.Stop()
$_sw.ElapsedMilliseconds | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-10.time") -NoNewline

# ---------------------------------------------------------------------------
# 11. Lockfile validation
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Lockfile validation ===" -f (++$_step))
"Lockfile validation" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step

# Consistency and overlap checks (always run, even in path-scoped mode):
  #  1. lockfile.json must exist.
  #  2. No package should appear in multiple package-manager sections.
  #     (Ollama is excluded because it uses a nested structure unrelated to
  #      package versions.)
  $_lfPath = Join-Path $RepoRoot "src\lockfiles\lockfile.json"
$_lf = $null
$_lfOverlapErrors = 0
if (-not (Test-Path $_lfPath)) {
  error "lockfile.json not found at $_lfPath"
  1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-11.exit") -NoNewline
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
      error ("package '{0}' appears in both {1}" -f $_entry.Key, ($_entry.Value -join ', '))
      $_lfOverlapErrors++
    }
  }
}
if ($_lfOverlapErrors -gt 0) {
  error ("lockfile.json consistency: {0} overlap issue(s)" -f $_lfOverlapErrors)
  1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-11.exit") -NoNewline
} else {
  say "lockfile.json consistency: no overlapping packages across sections"
}

# Lifecycle script allowlist validation (always run):
#  - lifecycle-allowlist.json must exist and be a valid JSON object.
#  - Each entry must have a non-empty justification string.
$_lfAlPath = Join-Path $RepoRoot "src\lockfiles\lifecycle-allowlist.json"
$_lfAlErrors = 0
if (-not (Test-Path $_lfAlPath)) {
  error "lifecycle-allowlist.json not found at $_lfAlPath"
  $_lfAlErrors++
} else {
  $_lfAlRaw = Get-Content $_lfAlPath -Raw -ErrorAction Stop
  $_lfAl = $null
  try {
    $_lfAl = ConvertFrom-Json $_lfAlRaw -AsHashtable
  } catch {
    error "lifecycle-allowlist.json is not valid JSON: $_($_.Exception.Message)"
    $_lfAlErrors++
  }
  if ($null -ne $_lfAl -and $_lfAl -isnot [hashtable]) {
    error "lifecycle-allowlist.json must be a JSON object"
    $_lfAlErrors++
  } elseif ($null -ne $_lfAl) {
    foreach ($_entry in $_lfAl.GetEnumerator()) {
      if ($_entry.Value -isnot [string] -or [string]::IsNullOrEmpty($_entry.Value)) {
        error "lifecycle-allowlist.json: '$_($_entry.Key)' has empty or non-string justification"
        $_lfAlErrors++
      }
    }
  }
}
if ($_lfAlErrors -gt 0) {
  error "lifecycle-allowlist.json validation failed with $_lfAlErrors error(s)"
  1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-11.exit") -NoNewline
} else {
  $_lfAlCount = if ($null -ne $_lfAl -and $_lfAl -is [hashtable]) { $_lfAl.Count } else { 0 }
  say ("lifecycle-allowlist.json: valid (entry count: {0})" -f $_lfAlCount)
}

# Always-run: Lockfile section validation
if ($null -eq $_lf) {
    error "lockfile.json could not be loaded — skipping section validation"
    1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-11.exit") -NoNewline
  } else {
    $_lfErrors = 0

    # Check sections that must be non-empty
    foreach ($_section in @('scoop', 'cargo-binstall', 'bun', 'uv', 'rustup', 'pwsh')) {
      if (-not $_lf.ContainsKey($_section) -or $_lf[$_section].Count -eq 0) {
        error "${_section}: empty or missing section"
        $_lfErrors++
      } else {
        foreach ($_entry in $_lf[$_section].GetEnumerator()) {
          if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
            error "${_section}.$($_entry.Key): placeholder version ($($_entry.Value))"
            $_lfErrors++
          }
        }
      }
    }

    # winget: warn if empty
    if (-not $_lf.ContainsKey('winget')) {
      error "winget: missing section"
      $_lfErrors++
    } elseif ($_lf.winget.Count -gt 0) {
      foreach ($_entry in $_lf.winget.GetEnumerator()) {
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
          error "winget.$($_entry.Key): placeholder version ($($_entry.Value))"
          $_lfErrors++
        }
      }
    } else {
      say "warning: winget: empty section (not yet populated)"
    }

    # vscode: warn if empty
    if (-not $_lf.ContainsKey('vscode')) {
      error "vscode: missing section"
      $_lfErrors++
    } elseif ($_lf.vscode.Count -gt 0) {
      foreach ($_entry in $_lf.vscode.GetEnumerator()) {
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
          error "vscode.$($_entry.Key): placeholder version ($($_entry.Value))"
          $_lfErrors++
        }
      }
    } else {
      say "warning: vscode: empty section (not yet populated)"
    }

    # homebrew: must be non-empty
    if (-not $_lf.ContainsKey('homebrew') -or $_lf.homebrew.Count -eq 0) {
      error "homebrew: empty or missing section"
      $_lfErrors++
    }

    # ollama: must have at least one profile with models
    if (-not $_lf.ContainsKey('ollama') -or $_lf.ollama.Count -eq 0) {
      error "ollama: empty or missing section"
      $_lfErrors++
    } else {
      foreach ($_profile in $_lf.ollama.GetEnumerator()) {
        if ($_profile.Value.Count -eq 0) {
          error "ollama.$_($_profile.Key): empty model list"
          $_lfErrors++
        } else {
          for ($_i = 0; $_i -lt $_profile.Value.Count; $_i++) {
            $_model = $_profile.Value[$_i]
            if ([string]::IsNullOrEmpty($_model.name) -or [string]::IsNullOrEmpty($_model.tag)) {
              error "ollama.$_($_profile.Key)[$_i]: missing name or tag"
              $_lfErrors++
            }
          }
        }
      }
    }

    if ($_lfErrors -gt 0) {
      error "lockfile.json validation failed with $_lfErrors error(s)"
      1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-11.exit") -NoNewline
    } else {
      say "lockfile.json validation passed"
    }
  }
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-11.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 12. Locked DSC validation
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Locked DSC validation ===" -f (++$_step))
"Locked DSC validation" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
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
        error "system DSC files: $_id has version $_pinnedVer but no lockfile entry"
        $_lfErrors++
      } elseif ($_pinnedVer -ne $_lfVer) {
        error "system DSC files: $_id pinned $_pinnedVer but lockfile has $_lfVer"
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
      error "$_id ($_lfVer) is in lockfile but missing version pin after generation"
      $_lfErrors++
    }
  }

  if ($_lfErrors -gt 0) {
    error "locked DSC validation failed with $_lfErrors error(s)"
    1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-12.exit") -NoNewline
  } else {
    say "locked DSC validation passed"
  }
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-12.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 13. Schema validation (JSON/YAML)
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Schema validation (JSON/YAML) ===" -f (++$_step))
"Schema validation (JSON/YAML)" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $HAS_ARGS, $positionalArgs, $RepoRoot, $WaveTmpDir, $_stepStartTicks, $parallelJobs)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
  # Build manifest of file→schema pairs.
  # Each entry: @{SchemaFile=...; InstanceFile=...}
  $manifest = [System.Collections.Generic.List[hashtable]]::new()
  if ($HAS_ARGS) {
    foreach ($_sf in $positionalArgs) {
      if ($_sf -like '*.json') {
        $_schema = try { (Get-Content $_sf -Raw | ConvertFrom-Json -AsHashtable)['$schema'] } catch { $null }
        if ($_schema) {
          if ($_schema -match '^\.') {
            $_schemafile = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $_sf -Parent) $_schema))
          } else {
            $_schemafile = $_schema
          }
          $manifest.Add(@{SchemaFile=$_schemafile; InstanceFile=$_sf})
        }
      } elseif ($_sf -like '*.yml' -or $_sf -like '*.yaml') {
        $_schema = try { ($_sf | Get-Content -Raw | ConvertFrom-Yaml)['$schema'] } catch { $null }
        if ($_schema) {
          if ($_schema -match '^\.') {
            $_schemafile = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $_sf) $_schema))
          } else {
            $_schemafile = $_schema
          }
          $manifest.Add(@{SchemaFile=$_schemafile; InstanceFile=$_sf})
        }
      }
    }
  } else {
    # JSON files
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
        $manifest.Add(@{SchemaFile=$_schemafile; InstanceFile=$_.FullName})
      }
    }
    # YAML files
    Get-ChildItem -Recurse -Path $RepoRoot -Include '*.yml','*.yaml' | Where-Object {
      $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.FullName -notmatch '[/\\]secrets[/\\]'
    } | ForEach-Object {
      $_schema = try { ($_ | Get-Content -Raw | ConvertFrom-Yaml)['$schema'] } catch { $null }
      if ($_schema) {
        if ($_schema -match '^\.') {
          $_schemafile = [System.IO.Path]::GetFullPath((Join-Path $_.DirectoryName $_schema))
        } else {
          $_schemafile = $_schema
        }
        $manifest.Add(@{SchemaFile=$_schemafile; InstanceFile=$_.FullName})
      }
    }
  }
  # Group by schemafile and dispatch parallel jobs
  $_jsonschemaErrors = 0
  if ($manifest.Count -gt 0) {
    $groups = $manifest | Group-Object SchemaFile
    $validationJobs = $groups | ForEach-Object -Parallel -ThrottleLimit $using:parallelJobs {
      $SchemaFile = $_.Name
      $InstanceFiles = @($_.Group.InstanceFile)
      Set-StrictMode -Version Latest
      $ErrorActionPreference = 'Stop'
      $output = check-jsonschema --schemafile $SchemaFile $InstanceFiles 2>&1
      $exitCode = $LASTEXITCODE
      if ($exitCode -ne 0) {
        return @{SchemaFile=$SchemaFile; ExitCode=$exitCode; Output="$output"}
      }
      return @{SchemaFile=$SchemaFile; ExitCode=$exitCode; Output=$null}
    }
    foreach ($r in $validationJobs) {
      if ($r.ExitCode -ne 0) {
        $_jsonschemaErrors++
        if ($r.Output) { error $r.Output }
      }
    }
  }
  # GitHub schema validation — always-run
  $_ghWorkflows = Join-Path $RepoRoot '.github\workflows\*.yml'
  check-jsonschema --builtin-schema vendor.github-workflows $_ghWorkflows
  if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
  $_dependabot = Join-Path $RepoRoot '.github\dependabot.yml'
  if (Test-Path $_dependabot) {
    check-jsonschema --builtin-schema vendor.dependabot $_dependabot
    if ($LASTEXITCODE -ne 0) { $_jsonschemaErrors++ }
  }
  if ($_jsonschemaErrors -gt 0) {
    error "schema validation failed with $_jsonschemaErrors error(s)"
    1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-13.exit") -NoNewline
  }
  say "schema validation passed."
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-13.time") -NoNewline
} -ArgumentList $_step, $HAS_ARGS, $positionalArgs, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks, $script:parallelJobs

# ---------------------------------------------------------------------------
# 14. Service registry validation
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Service registry validation ===" -f (++$_step))
"Service registry validation" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
  # Always-run: Service registry validation
$_svcJson = Join-Path $RepoRoot "src\modules\services.json"
$_svcErrors = 0

if (-not (Test-Path $_svcJson)) {
    error "services.json not found at $_svcJson"
    $_svcErrors++
  } else {
    $_svc = Get-Content $_svcJson -Raw | ConvertFrom-Json -AsHashtable

    foreach ($_svcName in $_svc.Keys) {
      if ($_svcName -like '$*') { continue }
      $_entry = $_svc[$_svcName]
      if ($_entry -isnot [hashtable]) { continue }
      if (-not $_entry.ContainsKey('displayName') -or [string]::IsNullOrEmpty($_entry.displayName)) {
        error "services.json: '$_svcName' missing displayName"
        $_svcErrors++
      }
      if (-not $_entry.ContainsKey('platforms') -or $_entry.platforms.Count -eq 0) {
        error "services.json: '$_svcName' missing or empty platforms"
        $_svcErrors++
      } else {
        foreach ($_plat in $_entry.platforms.Keys) {
          $_pEntry = $_entry.platforms[$_plat]
          $_type = $_pEntry.type
          if ($_type -notin @('launchctl', 'systemctl', 'native', 'schtask', 'omitted')) {
            error "services.json: '$_svcName' platform '$_plat' has invalid type '$_type'"
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
            error "services.json: '$_svcName' platform '$_plat' missing required fields for type '$_type'"
            $_svcErrors++
          }
        }
      }
    }
  }

  if ($_svcErrors -gt 0) {
    error "services.json validation failed with $_svcErrors error(s)"
    1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-14.exit") -NoNewline
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
            error "services.json: '$_svcName' platform '$_plat' is user-scoped but missing justification"
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
              error "${_usersJson}: user '$_username' references unknown service '$_svcKey'"
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
                error "${_winUsersJson}: user '$_username' references unknown service '$_svcKey'"
                $_svcErrors++
              }
            }
          }
        }
      }
    }

    if ($_svcErrors -gt 0) {
      error "services.json validation failed with $_svcErrors error(s)"
      1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-14.exit") -NoNewline
    }
    say "services.json validation passed"
  }
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-14.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 15. YAML structural validation
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] YAML structural validation ===" -f (++$_step))
"YAML structural validation" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $HAS_ARGS, $positionalArgs, $CachedYamlFiles, $WaveTmpDir, $_stepStartTicks, $parallelJobs)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
  $_yamlErrors = 0
$_yamlFiles = @()
if ($HAS_ARGS) {
  $_yamlFiles = $positionalArgs | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' }
} else {
  $_yamlFiles = $CachedYamlFiles |
    Where-Object { $_.FullName -notmatch '[/\\]secrets[/\\]' } |
    ForEach-Object { $_.FullName }
}
$_yamlFileErrors = $_yamlFiles | ForEach-Object -Parallel -ThrottleLimit $using:parallelJobs {
  $_yf = $_
  # Validate
  try {
    $_content = Get-Content $_yf -Raw -ErrorAction Stop
    $null = $_content | ConvertFrom-Yaml -ErrorAction Stop
    return $null
  } catch {
    return "$_yf"
  }
}
foreach ($_yfe in $_yamlFileErrors) {
  if ($_yfe) {
    error "$($_yfe): invalid YAML"
    $_yamlErrors++
  }
}
if ($_yamlErrors -gt 0) {
  error "YAML structural validation failed with $_yamlErrors error(s)"
  1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-15.exit") -NoNewline
}
say "YAML structural validation passed."
$_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
$_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
$_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-15.time") -NoNewline
} -ArgumentList $_step, $HAS_ARGS, $positionalArgs, $script:CachedYamlFiles, $script:WaveTmpDir, $_stepStartTicks, $script:parallelJobs

# ---------------------------------------------------------------------------
# 16. Package manager usage enforcement
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Package manager usage enforcement ===" -f (++$_step))
"Package manager usage enforcement" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
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
    error "bare pip install detected (use uv pip install instead)"
    $_violations++
  }
  $_npmViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$RepoRoot\scripts","$RepoRoot\src","$RepoRoot\tests" `
      -Include *.sh,*.ps1,*.nix `
      -Exclude check.sh,check.ps1,shell.nix `
      | ForEach-Object { $_.FullName }
    ) -Pattern '(^|[^a-z])npm install([^-]|$)'
  if ($_npmViolations) {
    error "bare npm install detected (use bun or nix instead)"
    $_violations++
  }
  if ($_violations -gt 0) {
    1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-16.exit") -NoNewline
  } else {
    say "no package manager violations found."
  }
  $_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
  $_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
  $_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-16.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 17. Undocumented error suppression check
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Undocumented error suppression check ===" -f (++$_step))
"Undocumented error suppression check" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $HAS_ARGS, $SH_FILES, $NIX_FILES, $PS1_FILES, $WaveTmpDir, $_stepStartTicks)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step

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
    error $_uv
  }
  error ("undocumented error suppression check failed with {0} violation(s)" -f $_undocSuppViolations.Count)
  say "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
  1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-17.exit") -NoNewline
} else {
  say "no undocumented error suppressions found."
}
$_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
$_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
$_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-17.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $HAS_ARGS, $script:SH_FILES, $script:NIX_FILES, $script:PS1_FILES, $script:WaveTmpDir, $_stepStartTicks

# ---------------------------------------------------------------------------
# 18. Online determinism checks (--verify mode only)
# ---------------------------------------------------------------------------
$_sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output ("`n=== [{0}] Online determinism checks (--verify) ===" -f (++$_step))
"Online determinism checks (--verify)" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
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
$_sw.Stop()
$_sw.ElapsedMilliseconds | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-18.time") -NoNewline

# ---------------------------------------------------------------------------
# 19. Config method compliance
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Config method compliance ===" -f (++$_step))
"Config method compliance" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $WaveTmpDir, $_stepStartTicks, $parallelJobs)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
  $_cfgDir = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs"
$_cfgErrors = 0

# Always-run: Config method compliance
# Single-pass: collect all config file basenames, run one Select-String across src/
$_cfgFiles = Get-ChildItem -Path $_cfgDir -Recurse -File
$_srcFiles = Get-ChildItem -Path (Join-Path $RepoRoot "src") -Recurse -Include '*.nix', '*.ps1', '*.sh' |
  Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' -and $_.FullName -notmatch '[\\/]configs[\\/]' }
$_cfgPatterns = @($_cfgFiles | ForEach-Object { [regex]::Escape($_.Name) } | Sort-Object -Unique)
$_cfgSelectOutput = $_srcFiles | Select-String -Pattern $_cfgPatterns -SimpleMatch
# Single-pass: collect all # Method lines for preceding-line checking
$_cfgMethodOutput = $_srcFiles | Select-String -Pattern '# Method'

$_cfgFileErrors = $_cfgFiles | ForEach-Object -Parallel -ThrottleLimit $using:parallelJobs {
  param($_cfgDir, $_cfgSelectOutput, $_cfgMethodOutput)
  $_basename = $_.Name

  # Skip infrastructure files and Nix modules inside configs/
  if ($_basename -in '.gitkeep', '.gitignore') { return $null }
  if ($_basename -like '*.schema.json') { return $null }
  if ($_basename -eq 'qtpass.nix') { return $null }

  # Skip agent customization files (consumed as a directory via Method 4)
  $_relPath = $_.FullName.Substring($_cfgDir.Length + 1) -replace '\\', '/'
  if ($_relPath -like 'agents/*') { return $null }

  # Check against cached Select-String output — relative path first, then basename
  $_refs = @($_cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($_relPath) })
  if ($_refs.Count -eq 0) {
    $_refs = @($_cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($_basename) })
  }

  if ($_refs.Count -eq 0) {
    return "$_relPath : no references found in src/ (excluding configs/) — orphaned config?"
  }

  $_hasMethod = $false
  foreach ($_ref in $_refs) {
    if ($_ref.Line -match '# Method') {
      $_hasMethod = $true
      break
    }
    # Check preceding line using cached # Method output
    if ($_ref.LineNumber -gt 1) {
      $_prevLineNum = $_ref.LineNumber - 1
      $_prevMatch = $_cfgMethodOutput | Where-Object { $_.Path -eq $_ref.Path -and $_.LineNumber -eq $_prevLineNum }
      if ($_prevMatch) {
        $_hasMethod = $true
        break
      }
    }
  }
  if (-not $_hasMethod) {
    return "$_relPath : referenced but no '# Method N' comment found on or before reference lines"
  }

  return $null
}

foreach ($_cfe in $_cfgFileErrors) {
  if ($_cfe) {
    error $_cfe
    $_cfgErrors++
  }
}

if ($_cfgErrors -gt 0) {
  error ("config method compliance check failed with {0} error(s)" -f $_cfgErrors)
  1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-19.exit") -NoNewline
} else {
  say "config method compliance passed."
}
$_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
$_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
$_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-19.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $script:WaveTmpDir, $_stepStartTicks, $script:parallelJobs

# ---------------------------------------------------------------------------
# 20. Activation script token placeholder in comment check
# ---------------------------------------------------------------------------
$_stepStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
Write-Output ("`n=== [{0}] Activation script token placeholder in comment check ===" -f (++$_step))
"Activation script token placeholder in comment check" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$($_step).name") -NoNewline
$null = Add-RunspaceTask -ScriptBlock {
  param($_step, $RepoRoot, $HAS_ARGS, $positionalArgs, $WaveTmpDir, $_stepStartTicks, $parallelJobs)
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  function say { Write-Output "[Step $_step] $args" }
  function error { Write-Output "[Step $_step] error: $args" }
  $null = $_step
  $_actPattern = '^\s*#.*__[A-Z][A-Z_]*__'
$_actViolations = @()
if ($HAS_ARGS) {
  $_actViolations = $positionalArgs | ForEach-Object -Parallel -ThrottleLimit $using:parallelJobs {
    param($_actPattern)
    if ($_ -like '*.sh' -or $_ -like '*.zsh') {
      Select-String -Path $_ -Pattern $_actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
    }
  }
} else {
  $_actFiles = Get-ChildItem -Recurse -Path (Join-Path $RepoRoot "src\scripts") -Include '*.sh','*.zsh' | ForEach-Object { $_.FullName }
  $_actViolations += Select-String -Path $_actFiles -Pattern $_actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
}
if ($_actViolations.Count -gt 0) {
  foreach ($_av in ($_actViolations | Sort-Object -Unique)) { error $_av }
  error "token placeholder strings found in script comments"
  1 | Out-File -FilePath (Join-Path $WaveTmpDir "step-20.exit") -NoNewline
} else {
  say "no token placeholder strings in script comments."
}
$_elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $_stepStartTicks
$_elapsedMs = [Math]::Round($_elapsedTicks * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
$_elapsedMs | Out-File -FilePath (Join-Path $WaveTmpDir "step-20.time") -NoNewline
} -ArgumentList $_step, $RepoRoot, $HAS_ARGS, $positionalArgs, $script:WaveTmpDir, $_stepStartTicks, $script:parallelJobs

# Wait for all runspace tasks to complete
if ($script:runspaceTasks.Count -gt 0) {
  foreach ($_task in $script:runspaceTasks) {
    $null = $_task.PS.EndInvoke($_task.Handle)
    $_task.PS.Dispose()
  }
}
$script:runspacePool.Dispose()

# Aggregate wave results — combined status table with step names
$_totalMs = 0
$_totalSteps = 20
$_failedSteps = ""
say "check results:"
for ($_s = 1; $_s -le $_totalSteps; $_s++) {
  $_exitFile = Join-Path $script:WaveTmpDir "step-$_s.exit"
  $_timeFile = Join-Path $script:WaveTmpDir "step-$_s.time"
  $_nameFile = Join-Path $script:WaveTmpDir "step-$_s.name"
  $_status = "-"
  if (Test-Path $_exitFile) {
    $_code = Get-Content $_exitFile -Raw
    if ($_code -ne '0') {
      $exitCode = 1
      $_status = "✗"
      if ($FAIL_FAST) { exit $exitCode }
    } else {
      $_status = "✓"
    }
  }
  $_ms = 0
  if (Test-Path $_timeFile) {
    $_ms = [int](Get-Content $_timeFile -Raw)
    $_totalMs += $_ms
  }
  $_name = ""
  if (Test-Path $_nameFile) { $_name = Get-Content $_nameFile -Raw }
  Write-Output ("  step {0,2}  {1}  {2,5} ms  {3}" -f $_s, $_status, $_ms, $_name)
  if ($_status -eq "✗") { $_failedSteps += "step $_s ($_name), " }
}
Write-Output ("  total:   {0,5} ms" -f $_totalMs)

# ---------------------------------------------------------------------------
if ($exitCode -ne 0) {
  error "some checks failed with exit code $exitCode"
  error "Failed steps: $($_failedSteps.TrimEnd(', '))"
  exit $exitCode
}
say "all checks passed."
