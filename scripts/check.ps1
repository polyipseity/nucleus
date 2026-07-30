# check.ps1 — Consolidated repository validation script (Windows).
#
# Thin orchestrator — sources check-lib.ps1 for framework, check-steps.ps1 for step
# registration, then runs the orchestration pipeline.
#
# See check-lib.ps1, step-runner.ps1, and files in check-steps/ for step logic.
#
# Arguments:
#   --full           Run all checks including whole-repo checks (default).
#   --scoped         Run only path-scopable checks.
#   --fail-fast      Exit immediately on first failure.
#   --no-fail-fast   Accumulate all failures (default).
#   --online         Run online determinism checks.
#   --skip-steps=<ids>  Skip steps with the given comma-separated IDs.
#   (paths)          Files to check; restricts --scoped to matching files.
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

$CheckDir = Join-Path $RepoRoot "src/scripts/checks"
$FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"
$null = $FrameworkDir  # consumed by check-lib.ps1 at runtime

. (Join-Path $CheckDir "check-lib.ps1")
. (Join-Path $CheckDir "check-steps.ps1")

Read-Argument $args
Test-Prerequisite
Invoke-StepPipeline
Format-StepSummary
