#!/usr/bin/env bash
# Fast pre-commit checks. PSScriptAnalyzer (slow rules excluded) runs inline.
#
# Thin orchestrator — sources check-lib.sh for framework, check-steps.sh for step
# registration, then runs the orchestration pipeline.
#
# See check-lib.sh, framework-lib.sh, and files in check-steps/ for step logic.
#
# Arguments:
#   --format      Format Nix files in-place (instead of just validating).
#   (paths)       Files to check; passes paths through to sub-checkers and
#                 skips whole-repo checks (always-run checks that don't support path filtering).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
# By default, all checks run and failures accumulate (report-at-end).
# Use --fail-fast to exit immediately on the first failure.
set -uo pipefail

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

# shellcheck source=../src/scripts/checks/check-lib.sh
. "$SCRIPT_DIR/../src/scripts/checks/check-lib.sh"
# shellcheck source=../src/scripts/checks/check-steps.sh
. "$SCRIPT_DIR/../src/scripts/checks/check-steps.sh"

parse_args "$@"
preflight_check
run_all_steps
aggregate_results
