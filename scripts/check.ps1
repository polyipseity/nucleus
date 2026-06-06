# check.ps1 — Consolidated repository validation script (Windows).
#
# Runs all Windows-compatible repository checks in sequence:
#   1. PowerShell syntax validation
#   2. Packer template validation
#
# Nix tests, deadnix, shellcheck, and script validation tests are skipped
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
Write-Output "`n=== [1/2] PowerShell syntax validation ==="
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
Write-Output "`n=== [2/2] Packer template validation ==="
if ($PKR_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-packer.ps1" $PKR_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-packer.ps1"
} else {
  Write-Output "Skipping (no Packer templates to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }

if ($exitCode -ne 0) {
  Write-Output "`nSome checks failed with exit code $exitCode."
  exit $exitCode
}
Write-Output "`nAll checks passed."
