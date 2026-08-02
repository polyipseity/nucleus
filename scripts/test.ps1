#Requires -Version 7.4
# test.ps1 — Repository test suite runner (Windows).
#
# Thin orchestrator — sources test-lib.ps1 for framework, test-steps.ps1 for step
# registration, then runs the orchestration pipeline.
#
# See test-lib.ps1, step-runner.ps1, and files in test-steps/ for step logic.
#
# Arguments:
#   --fail-fast         Exit immediately on first failure (default).
#   --no-fail-fast      Accumulate all failures.
#   --quiet             No-op (--quiet is POSIX-only; accepted for CLI parity).
#   --skip-steps=<ids>  Skip steps with the given comma-separated IDs.
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

Read-Argument $args
Test-Prerequisite
Invoke-StepPipeline
Format-StepSummary
