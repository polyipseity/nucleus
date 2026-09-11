#!/usr/bin/env bash
# Unit tests for src/scripts/lib/symlink-hardening.sh.
#
# Contract:
#   - an absent path is a no-op, because the managed paths are created by
#     post-linkGeneration seeders and the unprotect/protect passes legitimately run
#     before those seeders exist;
#   - a failed flag change is reported as an F1 error and returns non-zero, so the
#     caller's `set -eu` aborts the activation instead of silently continuing.
#
# Run with: bash tests/scripts/symlink-hardening-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
SH_LIB="$REPO_ROOT/src/scripts/lib/symlink-hardening.sh"
readonly SH_LIB

# Run one library function in a subshell so its `return` cannot end this suite.
# Combined output goes to OUT_FILE (a file, not a command substitution: the
# trailing newlines of an empty capture would otherwise be stripped and the
# "silent" assertion below could not distinguish empty from non-empty).
# Prints the helper's exit status.
run_helper() {
  local fn="$1" path="$2" out_file="$3" rc=0
  bash -c '. "$1"; "$2" test-context "$3"' _ "$SH_LIB" "$fn" "$path" >"$out_file" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# Assert that FN, called with PATH, succeeds without printing anything.
assert_helper_silent_ok() {
  local fn="$1" path="$2" label="$3" out_file rc out
  out_file="$(mktemp)"
  rc="$(run_helper "$fn" "$path" "$out_file")"
  out="$(cat "$out_file")"
  rm -f "$out_file"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "$label"
  else
    assert_fail "$label" "rc=$rc output=[$out]"
  fi
}

test_absent_path_is_silent_no_op() {
  local tmp fn
  tmp="$(mktemp -d)"
  for fn in _nucleus_protect_symlink _nucleus_unprotect_symlink; do
    assert_helper_silent_ok "$fn" "$tmp/absent" "$fn treats an absent path as a silent no-op"
  done
  rm -rf "$tmp"
}

# The immutable-flag call is only executable on a host whose PATH provides the
# tool. nucleus installs chattr nowhere, so the Linux branch is inert and cannot
# be exercised here; the skip keeps that gap visible instead of passing silently.
require_immutable_flag_support() {
  local label="$1"
  if command -v chflags >/dev/null 2>&1; then
    return 0
  fi
  assert_skip "$label" "chflags unavailable on this host; the Linux chattr branch is inert in nucleus"
  return 1
}

test_dangling_symlink_is_accepted() {
  local tmp fn
  if ! require_immutable_flag_support "_nucleus_protect_symlink accepts a dangling symlink"; then
    return 0
  fi
  tmp="$(mktemp -d)"
  ln -s "$tmp/gone" "$tmp/dangling"
  for fn in _nucleus_protect_symlink _nucleus_unprotect_symlink; do
    assert_helper_silent_ok "$fn" "$tmp/dangling" "$fn accepts a dangling symlink"
  done
  rm -rf "$tmp"
}

test_existing_symlink_is_accepted() {
  local tmp fn
  if ! require_immutable_flag_support "_nucleus_protect_symlink accepts an existing symlink"; then
    return 0
  fi
  tmp="$(mktemp -d)"
  : >"$tmp/target"
  ln -s "$tmp/target" "$tmp/live"
  for fn in _nucleus_protect_symlink _nucleus_unprotect_symlink; do
    assert_helper_silent_ok "$fn" "$tmp/live" "$fn accepts an existing symlink"
  done
  rm -rf "$tmp"
}

test_flag_failure_reports_f1_error() {
  local out rc=0
  # _nucleus_symlink_error takes (context, message, tool-output), so it is called
  # directly rather than through run_helper's two-argument form.
  out="$(bash -c '. "$1"; _nucleus_symlink_error test-context "could not clear uchg" "chflags: Operation not permitted"' _ "$SH_LIB" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && [ "${out#*test-context: error: could not clear uchg}" != "$out" ] &&
    [ "${out#*chflags: Operation not permitted}" != "$out" ]; then
    assert_pass "_nucleus_symlink_error returns 1 with an F1 error folding in the tool output"
  else
    assert_fail "_nucleus_symlink_error returns 1 with an F1 error folding in the tool output" "rc=$rc output=[$out]"
  fi
}

# Linux cannot set the immutable flag from a user-scope activation (chattr needs
# CAP_LINUX_IMMUTABLE), so the library must not invoke it: reinstating the call would
# fail EPERM and — because a genuine flag failure is fatal — abort every NixOS apply.
test_no_chattr_invocation() {
  if grep -qE 'chattr[[:space:]]+-h' "$SH_LIB"; then
    assert_fail "library does not invoke chattr" "found a chattr invocation in $SH_LIB"
  else
    assert_pass "library does not invoke chattr (NixOS protection is detection-based)"
  fi
}

test_policy_records_capability_requirement() {
  local policy="$REPO_ROOT/.agents/instructions/cross-host-feature-parity.instructions.md"
  if grep -q "CAP_LINUX_IMMUTABLE" "$policy"; then
    assert_pass "policy records why Linux cannot prevent symlink removal (CAP_LINUX_IMMUTABLE)"
  else
    assert_fail "policy records why Linux cannot prevent symlink removal (CAP_LINUX_IMMUTABLE)" "CAP_LINUX_IMMUTABLE not found in $policy"
  fi
}

test_absent_path_is_silent_no_op
test_dangling_symlink_is_accepted
test_existing_symlink_is_accepted
test_flag_failure_reports_f1_error
test_no_chattr_invocation
test_policy_records_capability_requirement
finish_tests
