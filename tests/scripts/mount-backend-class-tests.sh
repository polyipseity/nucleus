#!/usr/bin/env bash
# mount-backend-class-tests.sh — provider-failure classification on macOS.
#
# backend_class must separate the two provider classes the MODULE STATE distinguishes:
#
#   provider-refusal — the extension is PRESENT but switched off; transient, so the
#                      runner retries it after the user re-enables it.
#   provider-version — anything else: the extension IS listed yet the mount still failed,
#                      or its state could not be read (`unknown`); terminal, so the
#                      runner blocks at once instead of retrying.
#
# backend_class itself never inspects a macFUSE VERSION.  The version judgement is made in
# backend_prepare, which blocks provider-version when the installed macFUSE predates 5.4.0;
# what this suite pins is the module-state split alone.
#
# Collapsing the two into one value loses the classification AND loses the terminal
# verdict, which means retrying a provider failure that no retry can clear — the
# behaviour that produced the original restart storm (macFUSE 5.3.3 against 5.4.0).
#
# WHY the module-state function is stubbed rather than read: the real FSKit state lives in
# a /Library/Group Containers plist a suite must not depend on.  backend_class — the code
# under test — is the REAL function, and the stub only supplies the one input it cannot
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

# classify_with STATE PATTERN — stub the module state, write PATTERN into the capture,
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
# wrong on some host — which is why `transientClasses` was removed from services.json, and
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

finish_tests
