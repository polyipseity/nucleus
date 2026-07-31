#!/usr/bin/env bash
# Check-specific framework library.
# Sources step-runner.sh and sets check-specific defaults.
#
# Guard against re-sourcing — step files source this independently and
# re-sourcing would overwrite SCRIPT_DIR and REPO_ROOT.
[ -n "${_NUCLEUS_CHECK_LIB_SOURCED-}" ] && return
_NUCLEUS_CHECK_LIB_SOURCED=1

# Resolve SCRIPT_DIR relative to this file so it works when sourced from
# standalone step files without a pre-set SCRIPT_DIR.
_self="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)

# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# shellcheck source=../lib/step-runner.sh
. "$SCRIPT_DIR/../lib/step-runner.sh"

# Check-specific defaults
export FAIL_FAST=false
REPO_ROOT=$(derive_repo_root)
cd "$REPO_ROOT" || exit

usage() {
  usage_std "check.sh" "[--fail-fast|--no-fail-fast] [--scoped|--full] [--online] [--skip-steps=<ids>] [path ...]" "Run all repository validation checks in sequence. Use --scoped to skip whole-repo checks (path-scoped mode), --full to force whole-repo checks even with paths. Default: scoped if paths given, full otherwise. With arguments, passes paths through to supporting checkers. Use --fail-fast to exit immediately on first failure (default: accumulate all). Use --no-fail-fast to accumulate all failures (default). Use --online to additionally run online determinism checks (requires network). Use --skip-steps=<ids> to skip steps with the given comma-separated IDs."
}
