#!/usr/bin/env bash
# Fast pre-commit checks. PowerShell syntax only; full PSSA runs in the test pipeline (pre-push).
#
# Thin orchestrator — sources check-lib.sh for framework, check-steps.sh for step
# registration, then runs the orchestration pipeline.
#
# See check-lib.sh, step-runner.sh, and files in check-steps/ for step logic.
#
# Arguments:
#   --fail-fast       Exit immediately on first failure.
#   --no-fail-fast    Accumulate all failures (default).
#   --scoped          Skip whole-repo checks (path-scoped mode).
#   --full            Force whole-repo checks even with paths.
#   --online          Run online determinism checks.
#   --skip-steps=<ids>  Skip steps with the given comma-separated IDs.
#   (paths)           Files to check; passes paths through to sub-checkers and
#                     skips whole-repo checks (always-run checks that don't support path filtering).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
# By default, all checks run and failures accumulate (report-at-end).
# Use --fail-fast to exit immediately on the first failure.
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
  /*) _self="$_target" ;;
  *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)

_ORCH_SCRIPT_DIR="$SCRIPT_DIR"
_NUCLEUS_CHECKS_DIR="$(CDPATH='' cd -- "$_ORCH_SCRIPT_DIR/../src/scripts/checks" && pwd)"
# shellcheck source=../src/scripts/checks/check-lib.sh
. "$_NUCLEUS_CHECKS_DIR/check-lib.sh"
# shellcheck source=../src/scripts/checks/check-steps.sh
. "$_NUCLEUS_CHECKS_DIR/check-steps.sh"

# Disable Nix auto-GC for the whole scripted pipeline. The Data volume is
# frequently >90% full; Nix's default min-free (40GiB) then triggers auto-GC
# that deletes flake-input source trees another parallel step still needs
# mid-eval (see src/scripts/lib/lib.sh merge_nix_config). min-free = 0 keeps
# inputs stable across parallel steps.
NIX_CONFIG="$(merge_nix_config)"
export NIX_CONFIG

cd "$REPO_ROOT" || exit
parse_args "$@"
preflight_check
run_all_steps
aggregate_results
