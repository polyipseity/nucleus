#!/usr/bin/env bash
# mount-backend-class-tests.sh: provider-failure classification on macOS.
#
# backend_class must separate the two provider classes the MODULE STATE distinguishes:
#
#   provider-refusal: the extension is PRESENT but switched off; transient, so the
#                      runner retries it after the user re-enables it.
#   provider-version: anything else: the extension IS listed yet the mount still failed,
#                      or its state could not be read (`unknown`); terminal, so the
#                      runner blocks at once instead of retrying.
#
# backend_class itself never inspects a macFUSE VERSION.  The version judgement is made in
# backend_prepare, which blocks provider-version when the installed macFUSE predates 5.4.0;
# what this suite pins is the module-state split alone.
#
# Collapsing the two into one value loses the classification AND loses the terminal
# verdict, which means retrying a provider failure that no retry can clear, the
# behaviour that produced the original restart storm (macFUSE 5.3.3 against 5.4.0).
#
# WHY the module-state function is stubbed rather than read: the real FSKit state lives in
# a /Library/Group Containers plist a suite must not depend on.  backend_class, the code
# under test, is the REAL function, and the stub only supplies the one input it cannot
# obtain offline.
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# Source the backend under test (the guard is cleared so this subshell always gets a
# fresh definition rather than inheriting a half-initialised one).
unset _NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED
# shellcheck source=../../src/scripts/lib/mount-backend-darwin.sh
. "$REPO_ROOT/src/scripts/lib/mount-backend-darwin.sh"

CAPTURE="$(mktemp "${TMPDIR:-/tmp}/mbc-capture.XXXXXX")"
trap 'rm -f "$CAPTURE"' EXIT

# classify_with PATTERN: write PATTERN into the capture and print the REAL
# backend_class verdict.
classify_with() {
  local pattern="$1"
  printf '%s\n' "$pattern" >"$CAPTURE"
  backend_class "$CAPTURE"
}

# assert_class LABEL EXPECTED PATTERN
assert_class() {
  local label="$1" expected="$2" pattern="$3" got
  got="$(classify_with "$pattern")"
  if [ "$got" = "$expected" ]; then
    assert_pass "$label"
  else
    assert_fail "$label" "expected '$expected', got '$got'"
  fi
}

section "1" "nfs mount-grab failures are transient"

# The live diagnosis behind the arm: rclone nfsmount reports a mount the kernel
# would not grant as `failed to mount NFS volume: exit status 16` (EBUSY), and
# that line fell through every arm to mount-failed, whose terminal remedy
# blocked the mount instead of letting the retry re-grant it.
assert_class "an nfs mount-grab failure classifies as io-transient" \
  "io-transient" \
  'mount: /Users/admin/clouds/GoogleDrive failed with 16: failed to mount NFS volume: exit status 16'

# Control: the new pattern must not become a catch-all. A failure nothing
# recognises still answers mount-failed, the class whose remedy points at the
# record's own output.
assert_class "an unrecognised failure still classifies as mount-failed" \
  "mount-failed" '2026/10/12 ERROR : something this classifier does not know'

section "2" "the class decides retry policy, and the verdict is per-host"

# WHY the verdict is asserted per-host instead of against a declared list: it genuinely
# DIFFERS between hosts.  No backend emits a provider class any more: Linux never
# defined one, and macOS mounts moved to nfsmount, which never touches an extension.
# The Linux assertion below passes because an unknown token falls through to the
# terminal default by design, which is the contract that matters here.  A cross-host
# declaration could only be wrong on some host, which is why `transientClasses` was
# removed from services.json, and this suite's former cross-check against it was
# deleted with it rather than left asserting agreement with an absent field.  The
# real per-host classification is pinned below.
if backend_is_transient "io-transient"; then
  assert_pass "io-transient is transient on darwin"
else
  assert_fail "io-transient is transient on darwin" \
    "backend_is_transient returned non-zero — an io error would never be retried"
fi

# The Linux verdict is asserted in its OWN SUBSHELL.  Both backends define
# backend_is_transient, so sourcing the Linux one into this shell would let whichever
# definition came last silently shadow the other, and the check below would then be
# testing the wrong host's function.
if (
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  backend_is_transient "provider-refusal"
); then
  assert_fail "provider-refusal is TERMINAL on Linux" \
    "Linux retried a provider refusal — nothing there can re-enable the extension"
else
  assert_pass "provider-refusal is TERMINAL on Linux"
fi

if (
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  backend_is_transient "io-transient"
); then
  assert_pass "io-transient is transient on Linux"
else
  assert_fail "io-transient is transient on Linux" "a Linux io error would never be retried"
fi

section "3" "the auth class matches an HTTP status, not a millisecond"

# WHY this case: an rclone timestamp carries a millisecond field, and a bare
#   `401` in the auth pattern matched it, so an ordinary mount failure was
#   recorded as bad credentials and the operator was sent to re-authenticate
#   a mount whose remote was fine.
assert_class "a timestamp-only capture does not classify as auth" \
  "mount-failed" \
  '2026/10/08 12:58:41.401 NOTICE : mounting remote'

# The anchored pattern must still reach a real HTTP status, or the fix would
#   trade one misclassification for silently ignoring every genuine auth error.
assert_class "an explicit HTTP status still classifies as auth" \
  "auth" \
  'Failed to list files: HTTP status 401'

# The Linux classifier carries the same anchored pattern, asserted in its own
#   subshell for the same reason as the transient verdicts above: both backends
#   define backend_class, and the last source would shadow the first.
_linux_class="$(
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  printf '%s\n' '2026/10/08 12:58:41.401 NOTICE : mounting remote' >"$CAPTURE"
  backend_class "$CAPTURE"
)"
if [ "$_linux_class" = "mount-failed" ]; then
  assert_pass "linux: a timestamp-only capture does not classify as auth"
else
  assert_fail "linux-timestamp-auth" \
    "expected 'mount-failed', got '$_linux_class'; the Linux pattern still reads the millisecond field as auth"
fi

# ── an expired session is auth, and its status is anchored too ──────────────
# 421 is what an expired Apple session surfaced as on a live MacBook. It fell
# through every arm to mount-failed, whose remedy points the operator at remote
# configuration when the real action is a re-authentication.
assert_class "an HTTP 421 status classifies as auth" \
  "auth" \
  'Failed to list files: HTTP status 421'

assert_class "an invalid global session classifies as auth" \
  "auth" \
  'ERROR: iCloud root not found: Invalid global session'

# The same trap the 401 anchor guards, one digit over: 421 lands in the
#   millisecond field of an rclone timestamp (12:58:41.421) dozens of times a
#   second, so an unanchored 421 records an ordinary mount failure as bad
#   credentials. A timestamp carrying no status and no session phrase must
#   stay mount-failed.
assert_class "a timestamp-only capture with .421 does not classify as auth" \
  "mount-failed" \
  '2026/10/08 12:58:41.421 NOTICE : mounting remote'

# The Linux classifier carries the same anchored pattern, asserted in its own
#   subshell for the same shadowing reason as the verdicts above.
_linux_421_class="$(
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  printf '%s\n' 'Failed to list files: HTTP status 421' >"$CAPTURE"
  backend_class "$CAPTURE"
)"
if [ "$_linux_421_class" = "auth" ]; then
  assert_pass "linux: an HTTP 421 status classifies as auth"
else
  assert_fail "linux-421-auth" \
    "expected 'auth', got '$_linux_421_class'; the Linux pattern misses an expired session"
fi

_linux_421_ts_class="$(
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  printf '%s\n' '2026/10/08 12:58:41.421 NOTICE : mounting remote' >"$CAPTURE"
  backend_class "$CAPTURE"
)"
if [ "$_linux_421_ts_class" = "mount-failed" ]; then
  assert_pass "linux: a timestamp-only capture with .421 does not classify as auth"
else
  assert_fail "linux-421-timestamp-auth" \
    "expected 'mount-failed', got '$_linux_421_ts_class'; the Linux pattern reads the millisecond field as auth"
fi

section "4" "a clean unmount with no error is torn-down, and silence is no-output"

# rclone logs this NOTICE when a mounted volume is torn down cleanly. The live
# evidence behind the torn-down class: three drives attached, held under a
# second, and exited 0 with this line and no error at all, yet the fall-through
# recorded each as mount-failed, whose remedy sent the operator to check
# credentials for remotes that were fine.
UNMOUNT_NOTICE='2026/10/11 22:53:01 NOTICE : /Users/admin/clouds/iCloud: Unmounted rclone mount'

assert_class "an unmount-only capture classifies as torn-down" \
  "torn-down" "$UNMOUNT_NOTICE"

# The discriminating case: the ordering is what enforces "no error". A capture
# holding a real error AND the unmount NOTICE must stay the error class, because
# every error grep returns before the teardown predicate is reached. A single
# `grep -q Unmounted` placed ahead of the other tests breaks exactly here.
assert_class "an auth error followed by an unmount NOTICE still classifies as auth" \
  "auth" "$(printf 'Failed to list files: HTTP status 401\n%s' "$UNMOUNT_NOTICE")"

# A capture file nobody created arrives with no rclone words to justify any
# class, and its old mount-failed remedy told the operator to check remote
# configuration. no-output says the runner captured nothing and points at the
# runner log instead.
_missing_class="$(backend_class "$CAPTURE.absent")"
if [ "$_missing_class" = "no-output" ]; then
  assert_pass "a missing capture classifies as no-output"
else
  assert_fail "missing-capture-class" "expected 'no-output', got '$_missing_class'"
fi

_missing_remedy="$(backend_remedy no-output)"
case "$_missing_remedy" in
*"check remote configuration"*)
  assert_fail "no-output-remedy-not-credentials" \
    "remedy '$_missing_remedy' still sends the operator to remote configuration"
  ;;
*)
  assert_pass "no-output-remedy-not-credentials"
  ;;
esac
case "$_missing_remedy" in
*"runner log"*)
  assert_pass "no-output-remedy-points-at-the-runner-log"
  ;;
*)
  assert_fail "no-output-remedy-points-at-the-runner-log" \
    "remedy '$_missing_remedy' does not name the runner log"
  ;;
esac

# An existing-but-empty capture is the same silence: rclone wrote nothing to
# stderr, so every error grep misses and the old fall-through answered
# mount-failed with the credentials remedy.
: >"$CAPTURE"
_empty_class="$(backend_class "$CAPTURE")"
if [ "$_empty_class" = "no-output" ]; then
  assert_pass "an empty capture classifies as no-output"
else
  assert_fail "empty-capture-class" "expected 'no-output', got '$_empty_class'"
fi

# The torn-down remedy names the teardown itself. Sending the operator to
# credentials for a volume that mounted and was then unmounted cleanly is the
# misdiagnosis this class exists to end.
_torn_remedy="$(backend_remedy torn-down)"
case "$_torn_remedy" in
*credentials* | *"check remote configuration"*)
  assert_fail "torn-down-remedy-names-teardown" \
    "remedy '$_torn_remedy' points at credentials or configuration"
  ;;
*)
  assert_pass "torn-down-remedy-names-teardown"
  ;;
esac

# Both new classes are terminal: a teardown nothing explains and a silent
# rclone are not cleared by retrying, and retrying them is the restart storm
# the blocked-marker contract exists to prevent.
if backend_is_transient "torn-down"; then
  assert_fail "torn-down-is-terminal" "backend_is_transient returned 0 — a teardown would be retried forever"
else
  assert_pass "torn-down-is-terminal"
fi

if backend_is_transient "no-output"; then
  assert_fail "no-output-is-terminal" "backend_is_transient returned 0 — silence would be retried forever"
else
  assert_pass "no-output-is-terminal"
fi

# The default remedy's claim about the health record is only true when the
# record kept a capture file, which happens on the unreadable-table path alone.
# An unconditional claim pointed readers at evidence that was routinely absent.
_default_remedy="$(backend_remedy mount-failed)"
case "$_default_remedy" in
*"when present, the health record for this mount carries rclone's failing output"*)
  assert_pass "default remedy qualifies the health-record claim"
  ;;
*)
  assert_fail "default-remedy-qualifies-record-claim" \
    "remedy '$_default_remedy' asserts the record carries rclone's output unconditionally"
  ;;
esac

# The Linux classifier carries the same predicate and the same ordering,
# asserted in its own subshell for the same shadowing reason as above: both
# backends define backend_class, and the last source would shadow the first.
_linux_torn="$(
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  printf '%s\n' "$UNMOUNT_NOTICE" >"$CAPTURE"
  backend_class "$CAPTURE"
)"
if [ "$_linux_torn" = "torn-down" ]; then
  assert_pass "linux: an unmount-only capture classifies as torn-down"
else
  assert_fail "linux-torn-down-class" \
    "expected 'torn-down', got '$_linux_torn'; the Linux predicate misses the clean unmount"
fi

_linux_torn_auth="$(
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  printf 'Failed to list files: HTTP status 401\n%s\n' "$UNMOUNT_NOTICE" >"$CAPTURE"
  backend_class "$CAPTURE"
)"
if [ "$_linux_torn_auth" = "auth" ]; then
  assert_pass "linux: an auth error followed by an unmount NOTICE still classifies as auth"
else
  assert_fail "linux-torn-auth" \
    "expected 'auth', got '$_linux_torn_auth'; the Linux ordering lets the unmount swallow a real error"
fi

_linux_silent="$(
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  backend_class "$CAPTURE.absent"
)"
if [ "$_linux_silent" = "no-output" ]; then
  assert_pass "linux: a missing capture classifies as no-output"
else
  assert_fail "linux-missing-capture-class" \
    "expected 'no-output', got '$_linux_silent'; the Linux fall-through still blames the remote"
fi

_linux_default_remedy="$(
  unset _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
  # shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
  . "$REPO_ROOT/src/scripts/lib/mount-backend-linux.sh"
  backend_remedy mount-failed
)"
case "$_linux_default_remedy" in
*"when present, the health record for this mount carries rclone's failing output"*)
  assert_pass "linux: default remedy qualifies the health-record claim"
  ;;
*)
  assert_fail "linux-default-remedy-qualifies-record-claim" \
    "remedy '$_linux_default_remedy' asserts the record carries rclone's output unconditionally"
  ;;
esac

finish_tests
