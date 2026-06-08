# check.ps1 — Consolidated repository validation script (Windows).
#
# Runs all Windows-compatible repository checks in sequence:
#   1. PowerShell syntax validation
#   2. Packer template validation
#
# Tests (Nix test suite) are run separately via scripts/test.ps1.
# deadnix, shellcheck, and script validation tests are skipped
# on Windows (Nix/ShellCheck not available on Windows runners).
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

#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
$exitCode = 0

# Process -h|--help
if ($args.Count -gt 0 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
  Write-Output "Usage: check.ps1 [path ...]"
  Write-Output "  Run all Windows-compatible repository validation checks in sequence."
  Write-Output "  With arguments, passes paths through to supporting checkers."
  exit 0
}

$HAS_ARGS = $args.Count -gt 0

# Group paths by extension — each sub-checker receives only files it understands.
$PS1_FILES = @()
$PKR_FILES = @()
if ($HAS_ARGS) {
  foreach ($_f in $args) {
    if ($_f -like '*.ps1')     { $PS1_FILES += $_f }
    if ($_f -like '*.pkr.hcl') { $PKR_FILES += $_f }
  }
}

# ---------------------------------------------------------------------------
# 1. PowerShell syntax validation
# ---------------------------------------------------------------------------
Write-Output "`n=== [1/3] PowerShell syntax validation ==="
if ($PS1_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-pwsh.ps1" $PS1_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-pwsh.ps1"
} else {
  Write-Output "Skipping (no PowerShell scripts to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 2. Packer template validation
# ---------------------------------------------------------------------------
Write-Output "`n=== [2/3] Packer template validation ==="
if ($PKR_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-packer.ps1" $PKR_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-packer.ps1"
} else {
  Write-Output "Skipping (no Packer templates to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 3. Package manager usage enforcement
# ---------------------------------------------------------------------------
Write-Output "`n=== [3/3] Package manager usage enforcement ==="
if (-not $HAS_ARGS) {
  $_violations = 0
  # Ban bare pip install and npm install — these bypass the lockfile.
  # uv pip install is allowed.  Exclude self-references.
  $_pipViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$RepoRoot\scripts","$RepoRoot\src","$RepoRoot\tests" `
      -Include *.sh,*.ps1,*.nix `
      -Exclude check.sh,check.ps1 `
      | ForEach-Object { $_.FullName }
    ) -Pattern '(^|[^a-z])pip install([^-]|$)' `
    | Where-Object { $_.Line -notmatch 'uv pip install' }
  if ($_pipViolations) {
    Write-Output "ERROR: bare pip install detected (use uv pip install instead)"
    $_violations++
  }
  $_npmViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$RepoRoot\scripts","$RepoRoot\src","$RepoRoot\tests" `
      -Include *.sh,*.ps1,*.nix `
      | ForEach-Object { $_.FullName }
    ) -Pattern '(^|[^a-z])npm install([^-]|$)'
  if ($_npmViolations) {
    Write-Output "ERROR: bare npm install detected (use bun or nix instead)"
    $_violations++
  }
  if ($_violations -gt 0) {
    $exitCode = $_violations
  } else {
    Write-Output "No package manager violations found."
  }
} else {
  Write-Output "Skipping (path-scoped mode)."
}

if ($exitCode -ne 0) {
  Write-Output "`nSome checks failed with exit code $exitCode."
  exit $exitCode
}
Write-Output "`nAll checks passed."
