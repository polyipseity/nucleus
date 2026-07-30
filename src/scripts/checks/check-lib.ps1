#Requires -Version 7.4
# Check-specific framework library (PowerShell).
# Sources step-runner.ps1 and sets check-specific defaults.

Set-StrictMode -Version Latest

. (Join-Path $FrameworkDir "step-runner.ps1")

$script:FAIL_FAST = $false
$script:usageAction = {
  Write-Output "Usage: check.ps1 [--fail-fast|--no-fail-fast] [--scoped|--full] [--verify] [path ...]"
  Write-Output "  Run all Windows-compatible repository validation checks in sequence."
  Write-Output "  Use --scoped to skip whole-repo checks (path-scoped mode), --full to force"
  Write-Output "  whole-repo checks even with paths. Default: scoped if paths given, full if not."
  Write-Output "  --fail-fast      Exit immediately on first failure (default: accumulate all)."
  Write-Output "  --no-fail-fast    Accumulate all failures (default)."
  Write-Output "  --verify         Additionally run online determinism checks (requires network)."
}
# Output helpers
function Write-Message { Write-Output "check: $args" }
function Write-WarningMessage { Write-Output "check: warning: $args" }
function Write-ErrorMessage { Write-Output "check: error: $args" }

$modulesPath = Join-Path $RepoRoot 'src\hosts\Windows\modules'
Import-Module (Join-Path $modulesPath 'Ensure-Tool.psm1') -Force
