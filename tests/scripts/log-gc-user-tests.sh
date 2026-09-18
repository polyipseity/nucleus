#!/usr/bin/env bash
# Tests that the user log GC also rotates FUSE-T's own log directory, and that it
# does so only on macOS.
#
# The regression this guards: FUSE-T writes fuse-t.log/fuse-t.err under a hardcoded
# per-user path outside the nucleus log root and never rotates them, so a
# crash-looping mount grows them without bound unless the GC rotates that directory
# too.
#
# Run with: bash tests/scripts/log-gc-user-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
LOG_GC_USER_SH="$SCRIPT_DIR/../../src/scripts/services/log-gc-user.sh"

require_command awk "extract_func reads the script under test with awk"

# run_rotate_fuse_t_logs PLATFORM HOME_DIR MOCK_DIR — invoke the script-local
# rotate_fuse_t_logs in a child shell whose uname reports PLATFORM and whose
# rotation helpers record their arguments instead of touching files.
run_rotate_fuse_t_logs() {
  local platform="$1" home_dir="$2" mock_dir="$3"
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$platform" >"$mock_dir/uname"
  chmod +x "$mock_dir/uname"
  PATH="$mock_dir:$PATH" HOME="$home_dir" bash -c '
    . "$1"
    rotate_logs_in_directory() { echo "ROTATE $*" >> "$MOCK_RECORD"; }
    rotate_log_file() { echo "ROTATE_FILE $*" >> "$MOCK_RECORD"; }
    expire_logs_in_directory() { echo "EXPIRE $*" >> "$MOCK_RECORD"; }
    '"$(extract_func rotate_fuse_t_logs "$LOG_GC_USER_SH")"'
    rotate_fuse_t_logs 1000 4 true 7d
  ' nucleus-log-gc-user-test "$LIB_SH" >/dev/null 2>&1
}

test_fuse_t_logs_rotated_on_darwin() {
  local mock_dir work home_dir fb_dir rc=0
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  home_dir="$(mktemp -d)"
  fb_dir="$home_dir/Library/Logs/fuse-t"
  mkdir -p "$fb_dir"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  run_rotate_fuse_t_logs Darwin "$home_dir" "$mock_dir" || rc=$?

  if [ "$rc" -eq 0 ] &&
    grep -q "ROTATE $fb_dir " "$MOCK_RECORD" &&
    grep -q "ROTATE_FILE $fb_dir/fuse-t.err " "$MOCK_RECORD" &&
    grep -q "EXPIRE $fb_dir " "$MOCK_RECORD"; then
    assert_pass "the user log GC rotates FUSE-T's log directory on macOS"
  else
    assert_fail "fuse-t-rotate-darwin" "rc=$rc record=[$(cat "$MOCK_RECORD")]"
  fi
  rm -rf "$mock_dir" "$work" "$home_dir"
}

test_fuse_t_logs_skipped_off_darwin() {
  local mock_dir work home_dir rc=0
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  home_dir="$(mktemp -d)"
  mkdir -p "$home_dir/Library/Logs/fuse-t"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  run_rotate_fuse_t_logs Linux "$home_dir" "$mock_dir" || rc=$?

  if [ "$rc" -eq 0 ] && [ ! -s "$MOCK_RECORD" ]; then
    assert_pass "FUSE-T's log directory is left alone off macOS"
  else
    assert_fail "fuse-t-rotate-linux" "rc=$rc record=[$(cat "$MOCK_RECORD")]"
  fi
  rm -rf "$mock_dir" "$work" "$home_dir"
}

test_fuse_t_logs_skipped_without_directory() {
  local mock_dir work home_dir rc=0
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  home_dir="$(mktemp -d)"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  run_rotate_fuse_t_logs Darwin "$home_dir" "$mock_dir" || rc=$?

  if [ "$rc" -eq 0 ] && [ ! -s "$MOCK_RECORD" ]; then
    assert_pass "a host without FUSE-T installed rotates nothing"
  else
    assert_fail "fuse-t-rotate-absent" "rc=$rc record=[$(cat "$MOCK_RECORD")]"
  fi
  rm -rf "$mock_dir" "$work" "$home_dir"
}

test_unwritable_fuse_t_log_is_skipped() {
  local mock_dir work home_dir fb_dir rc=0
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  home_dir="$(mktemp -d)"
  fb_dir="$home_dir/Library/Logs/fuse-t"
  mkdir -p "$fb_dir"
  : >"$fb_dir/fuse-t.log"
  chmod 400 "$fb_dir/fuse-t.log"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  run_rotate_fuse_t_logs Darwin "$home_dir" "$mock_dir" || rc=$?

  if [ "$rc" -eq 0 ] && [ ! -s "$MOCK_RECORD" ]; then
    assert_pass "an unwritable FUSE-T log is skipped instead of failing the GC"
  else
    assert_fail "fuse-t-rotate-unwritable" "rc=$rc record=[$(cat "$MOCK_RECORD")]"
  fi
  chmod 600 "$fb_dir/fuse-t.log"
  rm -rf "$mock_dir" "$work" "$home_dir"
}

test_fuse_t_logs_rotated_on_darwin
test_fuse_t_logs_skipped_off_darwin
test_fuse_t_logs_skipped_without_directory
if [ "$(id -u)" -eq 0 ]; then
  assert_skip "unwritable FUSE-T log is skipped" "root bypasses file permissions"
else
  test_unwritable_fuse_t_log_is_skipped
fi
finish_tests
