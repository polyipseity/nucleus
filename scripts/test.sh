#!/usr/bin/env bash
# Runs the full repository test suite in sequence.
#
# Thin orchestrator — sources test-lib.sh for framework, test-steps.sh for step
# registration, then runs the orchestration pipeline.
#
# See test-lib.sh, framework-lib.sh, and files in test-steps/ for step logic.
#
# Arguments:
#   -q|--quiet           Suppress success/progress output across applicable steps.
#   --fail-fast          Exit immediately on first failure (default).
#   --no-fail-fast       Accumulate all failures.
#   --skip-system-build  Skip building the host system configuration.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
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

# shellcheck source=../src/scripts/tests/test-lib.sh
_ORCH_SCRIPT_DIR="$SCRIPT_DIR"
. "$_ORCH_SCRIPT_DIR/../src/scripts/tests/test-lib.sh"
# shellcheck source=../src/scripts/tests/test-steps.sh
. "$_ORCH_SCRIPT_DIR/../src/scripts/tests/test-steps.sh"

parse_args "$@"
preflight_check
run_all_steps
aggregate_results
