<#
.SYNOPSIS
  Repository test suite runner (Windows).

.DESCRIPTION
  Runs PSScriptAnalyzer lint on all PowerShell files.
  No Nix-based tests run on Windows (Nix test suite requires POSIX).
  Use --no-fail-fast to accumulate all failures. Default: fail-fast.

.EXAMPLE
  pwsh -File scripts/test.ps1
  pwsh -File scripts/test.ps1 --no-fail-fast

.NOTES
  Exit codes: 0 on success; non-zero on failure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exitCode = 0
$FAIL_FAST = $true

# Process flags
foreach ($_arg in $args) {
  if ($_arg -eq '-h' -or $_arg -eq '--help') {
    Write-Output "Usage: test.ps1 [--fail-fast|--no-fail-fast] [--skip-system-build]"
    Write-Output "  Run all Windows-compatible repository test suites."
    Write-Output "  --fail-fast            Exit immediately on first failure (default)."
    Write-Output "  --no-fail-fast          Accumulate all failures."
    Write-Output "  --skip-system-build     No-op (system config build is POSIX-only)."
    exit 0
  } elseif ($_arg -eq '--fail-fast') {
    $FAIL_FAST = $true
  } elseif ($_arg -eq '--no-fail-fast') {
    $FAIL_FAST = $false
  } elseif ($_arg -eq '--skip-system-build') {
    # No-op: system config build is POSIX-only.
  } else {
    Write-Output "test: error: unrecognized argument: $_arg"
    exit 1
  }
}

$_step = 0

# ---------------------------------------------------------------------------
# 1. PowerShell lint (PSScriptAnalyzer)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] PowerShell lint ===" -f (++$_step))
try {
  & "$PSScriptRoot\check-pwsh.ps1"
  $exitCode = 0
} catch {
  $exitCode = 1
}
if ($FAIL_FAST -and $exitCode -ne 0) { exit $exitCode }

Write-Output ""
Write-Output 'All tests passed.'
