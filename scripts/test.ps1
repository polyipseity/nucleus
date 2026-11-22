#Requires -Version 7.4
. (Join-Path $PSScriptRoot '..\src\scripts\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'
. (Join-Path $PSScriptRoot '..\src\scripts\lib\nucleus-cli-flags.ps1')
# test.ps1 - Repository test suite runner (Windows).
#
# Sources test-lib.ps1 for the framework and test-steps.ps1 for step
# registration, then runs the orchestration pipeline. Step logic lives in
# test-lib.ps1, step-runner.ps1, and files in test-steps/.
#
# Arguments:
#   --fail-fast         Exit immediately on first failure (default).
#   --no-fail-fast      Accumulate all failures.
#   --quiet             No-op (--quiet is POSIX-only; accepted for CLI parity).
#   --verbose[=<ids>]   Stream step output.
#   --no-verbose        Suppress step output streaming.
#   --scoped|--full     Select scoped or full mode.
#   --only-steps=<ids>  Run only steps with the given comma-separated IDs.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }

$TestDir = Join-Path $RepoRoot "src/scripts/tests"
$FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"
$null = $FrameworkDir  # check-suppress:suppression_doc: consumed by test-lib.ps1 at runtime

. (Join-Path $TestDir "test-lib.ps1")
. (Join-Path $TestDir "test-steps.ps1")
. (Join-Path $RepoRoot "src/scripts/lib/bundle-freshness.ps1")

$_listSteps = $false
$_listAction = ''
$_args = @($args)
$null = Resolve-NucleusCliFlag -Action ([ref]$_listAction) -Flags @{ 'list-steps' = '_listSteps' } -Arguments $_args # check-suppress:suppression_doc: helper returns remaining args; we only need the switch side effect here
if ($_listSteps -or $args -contains '--list-steps' -or $args -contains '-ListSteps') {
  Set-Location -Path $RepoRoot
  $FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"
  . (Join-Path $TestDir "test-lib.ps1")
  . (Join-Path $TestDir "test-steps.ps1")
  foreach ($id in $script:StepIds) { Write-Output $id }
  exit 0
}

Read-Argument $args
Test-Prerequisite
Write-BundleFreshnessNotice
Invoke-StepPipeline
Format-StepSummary
