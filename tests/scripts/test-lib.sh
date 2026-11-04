#!/usr/bin/env bash
# Shared test library: counters, assertions, and color helpers.
# Source this after setting SCRIPT_DIR and/or REPO_ROOT.

# Test state isolation, must run before any lib.sh / service-health.sh sourcing.
# Sets HOME and NUCLEUS_USER_ROOT to a temp dir so that derive_nucleus_user_root
# never resolves to the developer's real state directory.  lib.sh:38 uses
# ${VAR:=$(default)}, so any pre-set value is preserved and not overwritten.
init_test_state() {
  local _tmp_home _tmp_nucleus
  _tmp_home="$(mktemp -d)"
  _tmp_nucleus="$_tmp_home/.local/share/nucleus"
  mkdir -p "$_tmp_nucleus/state/service-stats"
  export HOME="$_tmp_home"
  export NUCLEUS_USER_ROOT="$_tmp_nucleus"
  # Prevent derive_repo_root from walking into the real repo tree.
  export NUCLEUS_REPO_ROOT="$_tmp_home/.repo"
  mkdir -p "$_tmp_home/.repo"
}

# Nothing initialises on source, every suite must call init_test_state
# itself BEFORE the first lib.sh / service-health.sh source, or it gets no
# isolation at all. svc-restart has no NUCLEUS_USER_ROOT handling of its own
# and relies on this initialiser alone.

# Console color detection (mirrors lib.sh _nuc_color_init): NO_COLOR set
# non-empty -> plain; FORCE_COLOR set and != "0" or CLICOLOR_FORCE set
# non-empty -> color; else color only when stdout is a tty ([ -t 1 ]) and
# TERM != dumb. Colors become empty strings when off so assert_* can print
# plain text with plain printf (no escape interpretation).
if [ -n "${NO_COLOR-}" ]; then
  TEST_COLOR=0
elif [ -n "${CLICOLOR_FORCE-}" ] || { [ -n "${FORCE_COLOR-}" ] && [ "$FORCE_COLOR" != "0" ]; }; then
  TEST_COLOR=1
else
  TEST_COLOR=0
  case "${TERM-}" in
  dumb) ;;
  *) [ -t 1 ] && TEST_COLOR=1 ;;
  esac
fi

if [ "$TEST_COLOR" -eq 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  CYAN='\033[1;36m'
  # shellcheck disable=SC2034 # reason: consumed by sibling test files (gen-completions-tests.sh, nucleus-apps-smoke-tests.sh) via sourcing
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  CYAN=''
  # shellcheck disable=SC2034 # reason: consumed by sibling test files (gen-completions-tests.sh, nucleus-apps-smoke-tests.sh) via sourcing
  YELLOW=''
  NC=''
fi

TESTS_PASSED=0
TESTS_FAILED=0

assert_pass() {
  local test_name="$1"
  if [ "$TEST_COLOR" -eq 1 ]; then
    printf '%s✓%s %s\n' "$GREEN" "$NC" "$test_name"
  else
    echo "✓ $test_name"
  fi
  ((++TESTS_PASSED))
}

assert_fail() {
  local test_name="$1"
  local reason="$2"
  if [ "$TEST_COLOR" -eq 1 ]; then
    printf '%s✗%s %s: %s\n' "$RED" "$NC" "$test_name" "$reason"
  else
    echo "✗ $test_name: $reason"
  fi
  ((++TESTS_FAILED))
}

# finish_tests: Print the tally and exit with the suite's status. Assertions only
# bump a counter, so a suite that never turns the tally into an exit status reports
# success to the runner, which sees only the exit status, no matter what it
# asserted. Must be the last statement of every suite that sources this library.
#
# There is no skip counter: a case that cannot run on this host asserts the
# host-correct expectation instead of stepping aside, so every case the suite
# claims to cover is a case the suite actually exercised.
#
# The status is computed with `if` rather than `[ … ] && _status=1`: under `set -e`
# a failing && list carries its own status, which would abort the function on the
# very runs that should be tallied. `exit`, not `return`: `return` at a script's
# top level is an error bash reports to stderr and then ignores, so an early-exit
# caller would print the failure and keep running.
finish_tests() {
  local _status=0
  if [ "$TESTS_FAILED" -gt 0 ]; then
    _status=1
    printf '\n%s%d passed, %d failed%s\n' "$RED" "$TESTS_PASSED" "$TESTS_FAILED" "$NC" >&2
  else
    printf '\n%s%d passed%s\n' "$GREEN" "$TESTS_PASSED" "$NC"
  fi
  # Machine-readable tally, asserted by test step 05. A suite that exits without
  # reaching this line cannot prove it ran its assertions, the one failure its
  # exit status alone cannot express.
  printf '# nucleus-tally passed=%d failed=%d\n' \
    "$TESTS_PASSED" "$TESTS_FAILED"
  exit "$_status"
}

# extract_func NAME FILE: print a top-level function definition (opening
# `NAME() {` through the column-0 closing `}`) from a script without executing the
# script body. Lets a suite exercise a script-local function in isolation.
extract_func() {
  awk -v name="$1" '$0 == name "() {" { p = 1 } p { print } p && $0 == "}" { p = 0; exit }' "$2"
}

# user_root_for_home HOME: print the per-user nucleus root for a HOME on this
# platform. Mirrors derive_nucleus_user_root (src/scripts/lib/lib.sh), which
# switches on `uname -s`: macOS nests the root under Library/Application Support,
# every other POSIX host under .local/share. Suites that seed state for a script
# running against the real platform must resolve the path the same way, or the
# markers they write land where the script never looks.
user_root_for_home() { # <home>
  case "$(uname -s)" in
  Darwin) printf '%s/Library/Application Support/nucleus\n' "$1" ;;
  *) printf '%s/.local/share/nucleus\n' "$1" ;;
  esac
}

# ensure_safe_rm_env: point safe-rm at a scratch trash of this run's own, so a
# suite's deletions neither land in the operator's Trash nor stop at an
# interactive "create the trash directory?" prompt. A provisioned host routes
# `rm` through safe-rm (file-deletion-safety.instructions.md), every suite in
# this directory deletes temp trees with `rm`, and a prompt on stdout corrupts
# every assertion that compares exact output.
#
# Both variables are exported together or not at all. A caller-supplied config
# without a caller-supplied trash is the broken half-pair: SAFE_RM_TRASH then
# defaults to $HOME/.Trash, which is absent in a test home. A complete pair is
# honored as given, which is how the check gate passes the operator's real
# config.
#
# Without safe-rm on PATH there is nothing to point anywhere: `rm` is the plain
# one, it asks no questions and keeps no trash. That is also how the suites run
# in CI, where neither bootstrap nor the test app provides safe-rm, so a missing
# safe-rm is reported in one line and left alone rather than failed.
#
# The trash directory sits in the system temp dir, outside every tree a suite
# deletes: safe-rm moves a deletion into the trash, and moving a directory into
# its own descendant fails, so a trash inside the suite's temp root would break
# that suite's own EXIT-trap cleanup. Nothing removes it afterwards for the same
# class of reason, the trap deletes after the tally and would only re-create and
# refill it; the platform's own temp cleanup is what bounds it.
ensure_safe_rm_env() {
  if ! command -v safe-rm >/dev/null 2>&1; then
    printf '%s: safe-rm not found, deletions run through the plain rm\n' "${0##*/}"
    return 0
  fi
  if [ -n "${SAFE_RM_CONFIG-}" ] && [ -n "${SAFE_RM_TRASH-}" ]; then
    return 0
  fi
  local _test_dir
  _test_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # Resolved, not spelled with ..: the exported value is asserted verbatim, and a
  # path that only means the fixture after resolution cannot be checked that way.
  _test_dir="$(CDPATH='' cd -- "$_test_dir/../fixtures/safe-rm" && pwd -P)"
  SAFE_RM_CONFIG="$_test_dir/config"
  SAFE_RM_TRASH="$(mktemp -d)"
  export SAFE_RM_CONFIG SAFE_RM_TRASH
}

# require_command: Fail the suite when a provisioned prerequisite is missing.
# Skip-guards are banned (tooling-and-validation.instructions.md): a missing tool
# is a suite failure the tally has to record, not a silent pass. finish_tests
# exits, so the call is terminal even from inside a function.
require_command() { # <name> <reason>
  command -v "$1" >/dev/null 2>&1 && return 0
  assert_fail "prerequisite: $1" "$2"
  finish_tests
}

# section; Print a section header to stdout (F3, mirrors lib.sh section()).
section() { printf '\n%s=== [%s] %s ===%s\n' "$CYAN" "$1" "$2" "$NC"; }
