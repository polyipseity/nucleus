#!/usr/bin/env bash
# Test-specific framework library.
# Sources framework-lib.sh and sets test-specific defaults.
#
# Guard against re-sourcing — step files source this independently and
# re-sourcing would overwrite SCRIPT_DIR and REPO_ROOT.
[ -n "${_NUCLEUS_TEST_LIB_SOURCED-}" ] && return
_NUCLEUS_TEST_LIB_SOURCED=1

# Resolve SCRIPT_DIR relative to this file so it works when sourced from
# standalone step files without a pre-set SCRIPT_DIR.
_self="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)

# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# shellcheck source=../lib/framework-lib.sh
. "$SCRIPT_DIR/../lib/framework-lib.sh"

# Test-specific defaults
FAIL_FAST=true
quiet_mode=false
skip_system_build=false
REPO_ROOT=$(derive_repo_root)
cd "$REPO_ROOT" || exit

# Override parse_args to add test-specific flags
parse_args() {
  quiet_mode=false
  skip_system_build=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -q|--quiet)
        # shellcheck disable=SC2034 # reason: consumed by test steps 01, 03, 04 via transitive sourcing
        quiet_mode=true
        shift
        ;;
      --fail-fast)
        FAIL_FAST=true
        shift
        ;;
      --no-fail-fast)
        FAIL_FAST=false
        shift
        ;;
      --skip-system-build)
        # shellcheck disable=SC2034 # reason: consumed by test step 04 (system-config-build) via transitive sourcing
        skip_system_build=true
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
  TEST_NIX_FILES=$(find tests -name '*.nix' -type f ! -name 'lib.nix' | sort)  # ref: EXCLUDE-LISTS.md#A6 — reason: test helper library excluded from namespace of test files
  # Self-pruning: verify excluded file still exists (A6)
  if [ ! -f "tests/lib.nix" ]; then
    error "stale exclusion: tests/lib.nix no longer exists — remove ! -name 'lib.nix' from find"
    return 1
  fi
  # shellcheck disable=SC2034 # reason: consumed by test step 01 (nix-tests) via transitive sourcing
  readarray -t TEST_NIX_FILES_ARR <<< "$TEST_NIX_FILES"
}

# Override preflight_check for test-specific tools
preflight_check() {
  require_command nix
  require_command nix-instantiate
  require_command pwsh
  require_command bash
  require_command find
  require_command xargs
}

usage() {
  usage_std "test.sh" "[-q|--quiet] [--fail-fast|--no-fail-fast] [--skip-system-build]" "Run the repository test suite. With --quiet, suppress success/progress output across applicable steps (failures always shown). By default, all output is shown. --fail-fast exits immediately on first failure (default); --no-fail-fast accumulates all failures. --skip-system-build skips building the system configuration."
}
