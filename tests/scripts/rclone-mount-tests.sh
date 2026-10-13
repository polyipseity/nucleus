#!/usr/bin/env bash
# rclone-mount-tests.sh: contract tests for the minimal rclone mount wrapper.
#
# The wrapper has exactly two modes: `mount <instance> <log-file> <mount-point>
# <remote-spec> [rclone-flags...]` cleans stale state and execs rclone in the
# foreground with output appended to the log file, and `clean <mount-point>`
# performs the clean step alone. There is no health record, no attach loop,
# and no classification: the mount table and the retained log are the whole
# failure surface.
#
# Fake `mount`, `umount`, and `rclone` executables are installed into a temp
# dir at the front of PATH so no real mount action can happen. The fake mount
# prints one table line only while FAKE_MOUNTED is exported, matching the
# wrapper's grep contract.
#
# Exit contract: finish_tests decides the status from the assertion counters;
# every individual wrapper invocation status is asserted explicitly.
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
. "$SCRIPT_DIR/test-lib.sh"

# HOME and NUCLEUS_USER_ROOT must resolve to a temp dir before any wrapper
# runs: during the RED run the pre-rewrite wrapper still writes health
# records, and those must never land in the real user state directory.
init_test_state

# Bound the pre-rewrite runner's retry budget so the RED run finishes in
# seconds instead of minutes. The new wrapper never reads these variables.
export NUCLEUS_MOUNT_ATTEMPTS=1
export NUCLEUS_MOUNT_BACKOFF=0
export NUCLEUS_MOUNT_ATTACH_SECONDS=1

WRAPPER="$REPO_ROOT/src/scripts/services/rclone-mount.sh"

# Every temp dir created by setup_fakes lands here so the suite leaves nothing
# behind in TMPDIR.
_TEMP_DIRS=()
# shellcheck disable=SC2329 # reason: invoked through the EXIT trap below, which the analyzer does not follow
cleanup_temp() {
  # check-suppress:suppression_doc: best-effort temp removal at suite exit; a failure leaves temp files, not bad assertions
  rm -rf ${_TEMP_DIRS[@]+"${_TEMP_DIRS[@]}"} 2>/dev/null || true
}
trap cleanup_temp EXIT

# assert_eq: compare actual against expected, report through the shared
# assertion counters. Argument order matches this suite's call sites.
assert_eq() { # <actual> <expected> <test name>
  if [ "$1" = "$2" ]; then
    assert_pass "$3"
  else
    assert_fail "$3" "expected '$2', got '$1'"
  fi
}

setup_fakes() {
  FAKEBIN="$(mktemp -d)"
  MNT_PARENT="$(mktemp -d)"
  MNT="$MNT_PARENT/cloudtest"
  LOG="$(mktemp -u).log"
  _TEMP_DIRS+=("$FAKEBIN" "$MNT_PARENT" "$LOG")
  cat >"$FAKEBIN/mount" <<'EOF'
#!/bin/bash
[ -n "${FAKE_MOUNTED:-}" ] && echo "localhost:/ on $FAKE_MOUNTED (nfs, nodev)"
exit 0
EOF
  cat >"$FAKEBIN/umount" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$FAKEBIN/umount.calls"
exit 0
EOF
  cat >"$FAKEBIN/rclone" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$FAKEBIN/rclone.calls"
echo "rclone-stderr-line" >&2
exit 0
EOF
  chmod +x "$FAKEBIN/mount" "$FAKEBIN/umount" "$FAKEBIN/rclone"
  export PATH="$FAKEBIN:$PATH"
}

section "1" "clean force-unmounts a stale entry, then recreates the directory"
setup_fakes
: >"$FAKEBIN/umount.calls"
export FAKE_MOUNTED="$MNT"
bash "$WRAPPER" clean "$MNT"
assert_eq "$(cat "$FAKEBIN/umount.calls")" "-f $MNT" "stale entry force-unmounted"
if [ -d "$MNT" ]; then
  assert_pass "mount point directory exists"
else
  assert_fail "mount point directory exists" "missing"
fi

section "2" "clean leaves a mounted non-empty directory in place and never calls rclone"
setup_fakes
: >"$FAKEBIN/rclone.calls"
export FAKE_MOUNTED="$MNT"
mkdir -p "$MNT" && touch "$MNT/keepme"
bash "$WRAPPER" clean "$MNT"
if [ -e "$MNT/keepme" ]; then
  assert_pass "non-empty directory untouched"
else
  assert_fail "non-empty directory untouched" "file vanished"
fi
if [ -s "$FAKEBIN/rclone.calls" ]; then
  assert_fail "clean never invokes rclone" "rclone was called"
else
  assert_pass "clean never invokes rclone"
fi

section "3" "mount cleans first, forwards every rclone argument, and keeps stderr"
setup_fakes
: >"$FAKEBIN/umount.calls"
: >"$FAKEBIN/rclone.calls"
export FAKE_MOUNTED="$MNT"
bash "$WRAPPER" mount test-instance "$LOG" "$MNT" testremote: --volname Cloud --read-only
if grep -qF -- "-f $MNT" "$FAKEBIN/umount.calls"; then
  assert_pass "mount mode cleans stale entry first"
else
  assert_fail "mount mode cleans stale entry first" "no umount call"
fi
# The fake rclone records its whole argument vector as one space-joined line
# (printf '%s\n' "$*"), so the expectation is built the same way.
expected_args="mount testremote: $MNT --volname Cloud --read-only"
actual_args="$(cat "$FAKEBIN/rclone.calls")"
assert_eq "$actual_args" "$expected_args" "rclone receives mount, remote, mount point, then flags verbatim"
if grep -q "rclone-stderr-line" "$LOG"; then
  assert_pass "rclone stderr lands in the log file"
else
  assert_fail "rclone stderr lands in the log file" "log missing"
fi

section "4" "unknown mode and missing arguments exit 2"
setup_fakes
bash "$WRAPPER" bogus a b >/dev/null 2>&1
rc="$?"
if [ "$rc" -eq 2 ]; then
  assert_pass "unknown mode exits 2"
else
  assert_fail "unknown mode exits 2" "status $rc"
fi
bash "$WRAPPER" mount only-one-arg >/dev/null 2>&1
rc="$?"
if [ "$rc" -eq 2 ]; then
  assert_pass "missing arguments exit 2"
else
  assert_fail "missing arguments exit 2" "status $rc"
fi

section "5" "clean skips umount when the mount table has no entry for the path"
setup_fakes
: >"$FAKEBIN/umount.calls"
unset FAKE_MOUNTED
bash "$WRAPPER" clean "$MNT"
if [ -s "$FAKEBIN/umount.calls" ]; then
  assert_fail "umount is not called for an unmounted path" "called: $(cat "$FAKEBIN/umount.calls")"
else
  assert_pass "umount is not called for an unmounted path"
fi
if [ -d "$MNT" ]; then
  assert_pass "mount point is still created"
else
  assert_fail "mount point is still created" "missing"
fi

finish_tests
