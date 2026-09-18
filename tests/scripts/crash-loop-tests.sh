#!/usr/bin/env bash
# Tests for src/scripts/lib/crash-loop.sh — restart timestamps are a
# comma-joined record, so counting, pruning, and loop detection must read the
# whole record rather than its first field.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/home"
export HOME="$_tmp/home"

# crash-loop.sh resolves lib.sh from its own directory, so it is sourced exactly
# the way a consumer does it — no SCRIPT_DIR juggling, no pre-sourcing of lib.sh.
# shellcheck source=../../src/scripts/lib/crash-loop.sh
. "$REPO_ROOT/src/scripts/lib/crash-loop.sh"
readonly REPO_ROOT

state_dir="$(crash_loop_state_dir)"
mkdir -p "$state_dir"
state_file="$state_dir/svc.json"

# count — Assert the number of restart timestamps the library reports.
assert_count() { # <test name> <expected>
  local actual
  actual="$(crash_loop_restart_count svc)"
  if [ "$2" = "$actual" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$actual'"
  fi
}

# assert_equal — Compare an actual value with the expected one.
assert_equal() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

# seed — Write <count> timestamps ending at <age> seconds ago.
seed() { # <count> <oldest age in seconds>
  jq -n --argjson count "$1" --argjson age "$2" --argjson now "$(date +%s)" \
    '{restarts: [range($now - $age; $now - $age + $count)], lastSuccess: 0}' >"$state_file"
}

section 1 "Counting restarts"
seed 12 11
assert_count "every recorded restart is counted" 12

seed 1 0
assert_count "a single restart is counted" 1

section 2 "Pruning"
seed 3 7200
crash_loop_record svc test
assert_count "restarts older than an hour are pruned" 1
if jq -e '.restarts | length == 1' "$state_file" >/dev/null; then
  assert_pass "the pruned state file keeps only recent restarts"
else
  assert_fail "the pruned state file keeps only recent restarts" "$(cat "$state_file")"
fi

seed 2 1
crash_loop_record svc test
assert_count "recording keeps the restarts already on file" 3

section 3 "Loop detection"
seed 4 3
if crash_loop_is_looping svc; then
  assert_fail "a few restarts are not a loop" "$(cat "$state_file")"
else
  assert_pass "a few restarts are not a loop"
fi

seed 10 9
if crash_loop_is_looping svc; then
  assert_pass "ten restarts in an hour are a loop"
else
  assert_fail "ten restarts in an hour are a loop" "$(cat "$state_file")"
fi

seed 4 3
crash_loop_success svc
assert_equal "a successful start clears consecutive failures" 0 "$(crash_loop_consecutive_failures svc)"
if crash_loop_is_looping svc; then
  assert_fail "a successful start makes few restarts non-looping" "$(cat "$state_file")"
else
  assert_pass "a successful start makes few restarts non-looping"
fi

section 4 "Caller-independent library resolution"
# Regression: crash-loop.sh sourced lib.sh through the *caller's* SCRIPT_DIR, so
# any consumer outside src/scripts/lib lost derive_nucleus_user_root and wrote
# its state to /state instead. A cold shell reproduces such a consumer: no
# SCRIPT_DIR, no lib.sh pre-sourced.
_cold_start="$(
  bash -c '
    . "$1/src/scripts/lib/crash-loop.sh"
    command -v derive_nucleus_user_root >/dev/null || { printf "UNDEFINED"; exit 0; }
    printf "%s" "$(crash_loop_state_dir)"
  ' _ "$REPO_ROOT"
)"
case "$_cold_start" in
"$HOME"/*)
  assert_pass "a consumer without SCRIPT_DIR still resolves the user root"
  ;;
*)
  assert_fail "a consumer without SCRIPT_DIR still resolves the user root" "$_cold_start"
  ;;
esac
case "$_cold_start" in
/state/*)
  assert_fail "the state dir is never rooted at /state" "$_cold_start"
  ;;
*)
  assert_pass "the state dir is never rooted at /state"
  ;;
esac

finish_tests
