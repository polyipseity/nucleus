#!/usr/bin/env bash
# Test-specific framework library.
# Sources step-runner.sh and sets test-specific defaults.
#
# Guard against re-sourcing — step files source this independently and
# re-sourcing would overwrite SCRIPT_DIR and REPO_ROOT.
[ -n "${_NUCLEUS_TEST_LIB_SOURCED-}" ] && return
_NUCLEUS_TEST_LIB_SOURCED=1

# Resolve SCRIPT_DIR relative to this file so it works when sourced from
# standalone step files without a pre-set SCRIPT_DIR.
_self="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)

NUCLEUS_LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/lib.sh
. "$NUCLEUS_LIB_DIR/lib.sh"
# shellcheck source=../lib/step-runner.sh
. "$NUCLEUS_LIB_DIR/step-runner.sh"

# Test-specific defaults
export FAIL_FAST=true
quiet_mode=false
REPO_ROOT=$(derive_repo_root)
cd "$REPO_ROOT" || exit

# Override parse_args to add test-specific flags
parse_args() {
  quiet_mode=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -q | --quiet)
      # shellcheck disable=SC2034 # reason: consumed by test steps 01, 04, 05 via transitive sourcing
      quiet_mode=true
      shift
      ;;
    --fail-fast)
      export FAIL_FAST=true
      shift
      ;;
    --no-fail-fast)
      export FAIL_FAST=false
      shift
      ;;
    --skip-steps=*)
      SKIP_STEPS=()
      _IFS_SAVE="$IFS"
      IFS=','
      for _id in ${1#--skip-steps=}; do
        _id="${_id## }"
        _id="${_id%% }"
        [ -n "$_id" ] || continue
        _skip_dup=false
        for _existing in "${SKIP_STEPS[@]}"; do
          [ "$_existing" = "$_id" ] && _skip_dup=true && break
        done
        $_skip_dup || SKIP_STEPS+=("$_id")
      done
      IFS="$_IFS_SAVE"
      shift
      ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
    esac
  done

  # No positional arguments accepted
  if [ "$#" -gt 0 ]; then
    error "unexpected argument '$1'"
    usage >&2
    exit 1
  fi
}

# Override cache_file_lists for test-specific file caching
cache_file_lists() {
  TEST_NIX_FILES=$(find tests -name '*.nix' -type f ! -name 'lib.nix' -print | filter_gitignored | sort) # ref: allow-and-deny-lists.instructions.md#A6 -- test helper library excluded from namespace of test files; gitignore filter applied on top
  # Self-pruning: verify excluded file still exists (A6)
  if [ ! -f "tests/lib.nix" ]; then
    error "stale exclusion: tests/lib.nix no longer exists — remove ! -name 'lib.nix' from find"
    return 1
  fi
  # shellcheck disable=SC2034 # reason: consumed by test step 01 (nix-tests) via transitive sourcing
  readarray -t TEST_NIX_FILES_ARR <<<"$TEST_NIX_FILES"
}

# Override preflight_check for test-specific tools
preflight_check() {
  require_command nix
  require_command nix-instantiate
  require_command pwsh
  require_command bash
  require_command find
  require_command xargs
  require_command jq
  require_command check-jsonschema
}

usage() {
  usage_std "test.sh" "[-q|--quiet] [--fail-fast|--no-fail-fast] [--skip-steps=<ids>]" "Run the repository test suite. With --quiet, suppress success/progress output across applicable steps (failures always shown). By default, all output is shown. --fail-fast exits immediately on first failure (default); --no-fail-fast accumulates all failures. --skip-steps=<ids> skips steps with the given comma-separated IDs."
}
