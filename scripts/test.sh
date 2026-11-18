#!/usr/bin/env bash
# Runs the full repository test suite with parallel step dispatch, Nix steps
# serialized behind a lock. Orchestrates only: test-lib.sh holds the framework,
# test-steps/ the step logic.
#
# Arguments:
#   -q|--quiet           Suppress success/progress output across applicable steps.
#   --fail-fast          Exit immediately on first failure (default).
#   --no-fail-fast       Accumulate all failures.
#   --verbose            Stream all step output (default: headers + summaries only).
#   --verbose=<ids>      Stream only the specified comma-separated step IDs.
#   --no-verbose         Suppress step output streaming (default).
#   --only-steps=<ids>   Run only the steps with the given comma-separated IDs.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exits non-zero on any check failure.
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

# shellcheck source=../src/scripts/lib/bash-guard.sh
. "$SCRIPT_DIR/../src/scripts/lib/bash-guard.sh"
bash_guard_require 5 1 test

_ORCH_SCRIPT_DIR="$SCRIPT_DIR"
_NUCLEUS_TESTS_DIR="$(CDPATH='' cd -- "$_ORCH_SCRIPT_DIR/../src/scripts/tests" && pwd)"
# shellcheck source=../src/scripts/tests/test-lib.sh
. "$_NUCLEUS_TESTS_DIR/test-lib.sh"
# shellcheck source=../src/scripts/tests/test-steps.sh
. "$_NUCLEUS_TESTS_DIR/test-steps.sh"

# Disable Nix auto-GC for the pipeline: the Data volume is often >90% full, and
# the 40GiB min-free then triggers a GC that deletes flake-input source trees
# another parallel step still needs (see merge_nix_config in
# src/scripts/lib/lib.sh). min-free = 0 keeps inputs stable.
NIX_CONFIG="$(merge_nix_config)"
export NIX_CONFIG

cd "$REPO_ROOT" || exit

for _arg in "$@"; do
  case "$_arg" in
  --list-steps)
    printf '%s\n' "${_STEP_IDS[@]}"
    exit 0
    ;;
  esac
done

parse_args "$@"
preflight_check
if [ -n "${NUCLEUS_PINNED_NIXPKGS:-}" ]; then
  say "nix pinning: pinned (NUCLEUS_PINNED_NIXPKGS set)"
else
  say "nix pinning: unpinned (will resolve from flakeInputs when needed)"
  say "nix pinning hint: if fetch/GC/403 blocks resolution, rerun with NUCLEUS_PINNED_NIXPKGS=\"\$NIX_PATH_PIN\" ./scripts/test.sh (no NIX_PATH=, no nix_path prefix)"
fi
run_all_steps
aggregate_results
