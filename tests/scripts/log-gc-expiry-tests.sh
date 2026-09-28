#!/usr/bin/env bash
# Unit tests for the log-retention resolver.
# NUCLEUS_GC_EXPIRY is a Nix GC knob that six log call sites used to read, so
# raising GC retention silently raised log retention. These tests pin the two
# apart: log retention comes from NUCLEUS_LOG_EXPIRY and nothing else.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
LOG_EXPIRY_LIB="$REPO_ROOT/src/scripts/lib/log-expiry.sh"
readonly REPO_ROOT LOG_EXPIRY_LIB

_log_expiry() {
  # shellcheck source=../../src/scripts/lib/log-expiry.sh
  . "$LOG_EXPIRY_LIB"
  resolve_log_expiry
}

test_log_expiry_defaults_to_seven_days() {
  local result
  result=$(
    unset NUCLEUS_LOG_EXPIRY NUCLEUS_GC_EXPIRY
    _log_expiry
  )
  if [ "$result" = "7d" ]; then
    assert_pass "log expiry defaults to 7d with no environment set"
  else
    assert_fail "log-expiry-default" "Expected 7d, got: $result"
  fi
}

# WHY: the coupling this pins is that NUCLEUS_GC_EXPIRY used to drive log
# retention, so raising GC retention silently raised log retention too.
test_log_expiry_ignores_gc_expiry() {
  local result
  result=$(
    unset NUCLEUS_LOG_EXPIRY
    # shellcheck disable=SC2034 # reason: read at runtime by the sourced lib, which shellcheck cannot follow
    NUCLEUS_GC_EXPIRY=99d
    _log_expiry
  )
  if [ "$result" = "7d" ]; then
    assert_pass "log expiry ignores NUCLEUS_GC_EXPIRY"
  else
    assert_fail "log-expiry-decoupled" "Expected 7d with NUCLEUS_GC_EXPIRY=99d, got: $result"
  fi
}

test_log_expiry_honours_its_own_variable() {
  local result
  result=$(
    # shellcheck disable=SC2034 # reason: read at runtime by the sourced lib, which shellcheck cannot follow
    NUCLEUS_LOG_EXPIRY=30d
    _log_expiry
  )
  if [ "$result" = "30d" ]; then
    assert_pass "log expiry honours NUCLEUS_LOG_EXPIRY"
  else
    assert_fail "log-expiry-own-var" "Expected 30d, got: $result"
  fi
}

# WHY: a resolver reading both would pass the default and the decoupling case
# while silently preferring the GC variable, so assert precedence explicitly.
test_own_variable_wins_over_gc_expiry() {
  local result
  result=$(
    # shellcheck disable=SC2034 # reason: read at runtime by the sourced lib, which shellcheck cannot follow
    NUCLEUS_LOG_EXPIRY=30d
    # shellcheck disable=SC2034 # reason: read at runtime by the sourced lib, which shellcheck cannot follow
    NUCLEUS_GC_EXPIRY=99d
    _log_expiry
  )
  if [ "$result" = "30d" ]; then
    assert_pass "NUCLEUS_LOG_EXPIRY wins over NUCLEUS_GC_EXPIRY"
  else
    assert_fail "log-expiry-precedence" "Expected 30d, got: $result"
  fi
}

# ---- Run tests ----

echo "--- log expiry ---"
test_log_expiry_defaults_to_seven_days
test_log_expiry_ignores_gc_expiry
test_log_expiry_honours_its_own_variable
test_own_variable_wins_over_gc_expiry

finish_tests
