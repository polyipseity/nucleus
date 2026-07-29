#Requires -Version 7.4
# test.ps1 — Repository test suite runner (Windows).
#
# Thin orchestrator — sources test-lib.ps1 for framework, test-steps.ps1 for step
# registration, then runs the orchestration pipeline.
#
# See test-lib.ps1, framework-lib.ps1, and files in test-steps/ for step logic.
#
# Arguments:
#   --fail-fast         Exit immediately on first failure (default).
#   --no-fail-fast      Accumulate all failures.
#   --skip-system-build No-op (accepted for CLI parity with test.sh).
#   --quiet             No-op (--quiet is POSIX-only; accepted for CLI parity).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }

$TestDir = Join-Path $RepoRoot "src/scripts/tests"
$FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"

. (Join-Path $TestDir "test-lib.ps1")
. (Join-Path $TestDir "test-steps.ps1")

Parse-Args $args
Preflight-Check
Run-AllSteps
Aggregate-Results
