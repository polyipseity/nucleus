#!/usr/bin/env bash
# Runs the full repository test suite with parallel step dispatch (Nix steps serialized via lock).
#
# Thin orchestrator — sources test-lib.sh for framework, test-steps.sh for step
# registration, then runs the orchestration pipeline.
#
# See test-lib.sh, step-runner.sh, and files in test-steps/ for step logic.
#
# Arguments:
#   -q|--quiet           Suppress success/progress output across applicable steps.
#   --fail-fast          Exit immediately on first failure (default).
#   --no-fail-fast       Accumulate all failures.
#   --skip-steps=<ids>   Skip steps with the given comma-separated IDs.
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

_ORCH_SCRIPT_DIR="$SCRIPT_DIR"
_NUCLEUS_TESTS_DIR="$(CDPATH='' cd -- "$_ORCH_SCRIPT_DIR/../src/scripts/tests" && pwd)"
# shellcheck source=../src/scripts/tests/test-lib.sh
. "$_NUCLEUS_TESTS_DIR/test-lib.sh"
# shellcheck source=../src/scripts/tests/test-steps.sh
. "$_NUCLEUS_TESTS_DIR/test-steps.sh"

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
