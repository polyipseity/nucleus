#!/usr/bin/env bash
# Tests for the POSIX VM wait helper: vm_wait_until bounds every wait and warns
# on timeout, and wait_for_utm_registration keeps its own probe, cadence, and
# timeout on top of it.
#
# Run with: bash tests/scripts/vm-tests.sh
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# WHY: the suite drives the product in-process, so the helper's warning text is
# asserted verbatim and color has to be off on the captured stderr.
export NO_COLOR=1
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/vm.sh
. "$REPO_ROOT/src/scripts/lib/vm.sh"

_tmp="$(mktemp -d)"
_real_utmctl="$UTMCTL"

# shellcheck disable=SC2329 # reason: dispatched by name from the EXIT trap
_cleanup() {
  rm -rf "$_tmp"
}
trap '_cleanup' EXIT

# Hermetic utmctl stub that runs BODY for every invocation, so the call-site
# cases need neither UTM nor a live hypervisor.
_write_fake_utmctl() {
  _wfut_body="$1"
  _wfut_path="$_tmp/utmctl"
  {
    printf '#!/bin/sh\n'
    printf '%s\n' "$_wfut_body"
  } >"$_wfut_path"
  chmod 755 "$_wfut_path"
  printf '%s\n' "$_wfut_path"
}

# A probe that never succeeds must return non-zero, and the timeout has to be
# the site's own: 1s here, never the helper inventing a bound.
test_wait_until_times_out() {
  local _start _elapsed _status=0 _err=''
  _start="$(date +%s)"
  _err="$(vm_wait_until "never to appear" 1 false 2>&1)" || _status=$?
  _elapsed=$(($(date +%s) - _start))
  if [ "$_status" -eq 0 ]; then
    assert_fail "wait_until times out" "returned 0 for a probe that never succeeds"
  elif [ "$_elapsed" -gt 3 ]; then
    assert_fail "wait_until times out" "waited ${_elapsed}s on a 1s timeout"
  elif ! printf '%s' "$_err" | grep -q 'timed out after 1s waiting for never to appear'; then
    assert_fail "wait_until times out" "no timeout warning naming the wait: $_err"
  else
    assert_pass "wait_until times out with a warning that names the wait"
  fi
}

test_wait_until_returns_on_success() {
  local _marker="$_tmp/waited.$$" _status=0
  : >"$_marker"
  vm_wait_until "marker" 5 test -f "$_marker" || _status=$?
  if [ "$_status" -eq 0 ]; then
    assert_pass "wait_until succeeds on the first probe"
  else
    assert_fail "wait_until returns on success" "returned $_status against an existing marker"
  fi
}

# A probe that starts succeeding only later separates "polls again" from
# "probes once and gives up".
test_wait_until_polls_until_success() {
  local _marker="$_tmp/late.$$" _status=0
  (
    sleep 1
    : >"$_marker"
  ) &
  vm_wait_until "late marker" 5 test -f "$_marker" || _status=$?
  wait
  if [ "$_status" -eq 0 ]; then
    assert_pass "wait_until polls until the probe succeeds"
  else
    assert_fail "wait_until polls until success" "returned $_status for a marker created 1s in"
  fi
}

# The call site keeps its own 15s default and its own utmctl probe; the timeout
# path is the only part that changed, from a silent return to a loud one.
test_wait_for_utm_registration_times_out() {
  local _start _elapsed _status=0 _err='' _fake
  _fake="$(_write_fake_utmctl 'echo "UUID Status Name"')"
  UTMCTL="$_fake"
  _start="$(date +%s)"
  _err="$(wait_for_utm_registration "absent-vm" 1 2>&1)" || _status=$?
  _elapsed=$(($(date +%s) - _start))
  UTMCTL="$_real_utmctl"
  if [ "$_status" -eq 0 ]; then
    assert_fail "wait_for_utm_registration times out" "returned 0 with no VM registered"
  elif [ "$_elapsed" -gt 3 ]; then
    assert_fail "wait_for_utm_registration times out" "waited ${_elapsed}s on a 1s timeout"
  elif ! printf '%s' "$_err" | grep -q "timed out after 1s waiting for UTM to register 'absent-vm'"; then
    assert_fail "wait_for_utm_registration times out" "no timeout warning naming the wait: $_err"
  else
    assert_pass "wait_for_utm_registration fails loudly through the shared helper"
  fi
}

# Success path through the real utmctl table parser: column 3 of a listing.
test_wait_for_utm_registration_detects_registered_vm() {
  local _status=0 _fake
  _fake="$(_write_fake_utmctl 'echo "UUID Status Name"
echo "0000 stopped registered-vm"')"
  UTMCTL="$_fake"
  wait_for_utm_registration "registered-vm" 5 || _status=$?
  UTMCTL="$_real_utmctl"
  if [ "$_status" -eq 0 ]; then
    assert_pass "wait_for_utm_registration returns once utmctl lists the VM"
  else
    assert_fail "wait_for_utm_registration detects a registration" "returned $_status for a listed VM"
  fi
}

test_wait_until_times_out
test_wait_until_returns_on_success
test_wait_until_polls_until_success
test_wait_for_utm_registration_times_out
test_wait_for_utm_registration_detects_registered_vm

finish_tests
