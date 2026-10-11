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

# An FSKit/provider-refusal line that backend_class's own regex matches.
FSKIT_PATTERN='File system extension not enabled'

# classify_with STATE PATTERN: stub the module state, write PATTERN into the capture,
# and print the REAL backend_class verdict.
classify_with() {
  local state="$1" pattern="$2"
  fskit_macfuse_module_state() { printf '%s\n' "$state"; }
  printf '%s\n' "$pattern" >"$CAPTURE"
  backend_class "$CAPTURE"
}

# assert_class LABEL EXPECTED STATE PATTERN
assert_class() {
  local label="$1" expected="$2" state="$3" pattern="$4" got
  got="$(classify_with "$state" "$pattern")"
  if [ "$got" = "$expected" ]; then
    assert_pass "$label"
  else
    assert_fail "$label" "expected '$expected', got '$got'"
  fi
}

section "1" "provider classification separates refusal from version"

assert_class "disabled extension classifies as provider-refusal" \
  "provider-refusal" "disabled" "$FSKIT_PATTERN"

assert_class "enabled extension with a failed mount classifies as provider-version" \
  "provider-version" "enabled" "$FSKIT_PATTERN"

# The other two inputs the branch must cover: an unreadable module list (`unknown`) and
# an unexpected/empty value.  Both are terminal, because the module state cannot explain
# the failure and a retry therefore cannot clear it.
assert_class "unknown module state classifies as provider-version" \
  "provider-version" "unknown" "$FSKIT_PATTERN"

assert_class "empty module state classifies as provider-version" \
  "provider-version" "" "$FSKIT_PATTERN"

# Control: the provider branch must not swallow other classes.  A non-provider pattern
# still has to reach its own verdict, proving the new branch is a split and not a
# catch-all.
assert_class "non-provider patterns still reach their own class (auth)" \
  "auth" "enabled" "Unauthorized (401)"

section "2" "the class decides retry policy, and the verdict is per-host"

if backend_is_transient "provider-refusal"; then
  assert_pass "provider-refusal is transient (retried)"
else
  assert_fail "provider-refusal is transient (retried)" "backend_is_transient returned non-zero"
fi

if backend_is_transient "provider-version"; then
  assert_fail "provider-version is terminal (not retried)" \
    "backend_is_transient returned 0 — a version mismatch would be retried forever"
else
  assert_pass "provider-version is terminal (not retried)"
fi

# WHY the verdict is asserted per-host instead of against a declared list: it genuinely
# DIFFERS between hosts.  darwin (and Windows) retry `provider-refusal`, because the user
# can switch the extension back on and the retry then succeeds; Linux must not, because
# nothing there can re-enable anything.  A cross-host declaration therefore could only be
# wrong on some host, which is why `transientClasses` was removed from services.json, and
# this suite's former cross-check against it was deleted with it rather than left asserting
# agreement with an absent field.  The real per-host classification is pinned below.
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
  "mount-failed" "enabled" \
  '2026/10/08 12:58:41.401 NOTICE : mounting remote'

# The anchored pattern must still reach a real HTTP status, or the fix would
#   trade one misclassification for silently ignoring every genuine auth error.
assert_class "an explicit HTTP status still classifies as auth" \
  "auth" "enabled" \
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
  "auth" "enabled" \
  'Failed to list files: HTTP status 421'

assert_class "an invalid global session classifies as auth" \
  "auth" "enabled" \
  'ERROR: iCloud root not found: Invalid global session'

# The same trap the 401 anchor guards, one digit over: 421 lands in the
#   millisecond field of an rclone timestamp (12:58:41.421) dozens of times a
#   second, so an unanchored 421 records an ordinary mount failure as bad
#   credentials. A timestamp carrying no status and no session phrase must
#   stay mount-failed.
assert_class "a timestamp-only capture with .421 does not classify as auth" \
  "mount-failed" "enabled" \
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

finish_tests
