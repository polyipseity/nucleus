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

# D5: fail early with copy-pastable remediation for incompatible bash runtimes.
# Never auto-switch runtimes; require bash >= 5.1 for the step runner (wait -n -p).
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 5 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 1 ]; }; then
  printf '%s\n' "error: incompatible bash runtime (${BASH_VERSION:-unknown}); bash >= 5.1 is required (step runner uses wait -n -p)." >&2
  printf '%s\n' "hint: rerun with a compatible bash, for example:" >&2
  # shellcheck disable=SC2016 # reason: show literal $USER/$PATH in copy-pastable remediation
  printf '%s\n' '  PATH="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$PATH" /run/current-system/sw/bin/bash ./scripts/test.sh' >&2
  exit 1
fi

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
