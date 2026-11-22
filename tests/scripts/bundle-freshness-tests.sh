#!/usr/bin/env bash
# Tests: warn_if_bundle_predates_tree reports a stale bundle, stays silent when the
# deployed revision matches HEAD, and never fails the caller.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../../src/scripts/lib/bundle-freshness.sh
. "$SCRIPT_DIR/../../src/scripts/lib/bundle-freshness.sh"

# shellcheck source=test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state

# Stub the one dependency the lib consumes that would otherwise reach the host,
# so the test needs no real bundle. The two revision seams are variables the lib
# reads first, which is what lets the test drive both revisions without a repo.
_bf_notices=()
_bf_stub_applied_rev=""
_bf_stub_head_rev=""
notice() { _bf_notices+=("$*"); }

_case_silent_when_revisions_match() {
  _bf_notices=()
  _NUCLEUS_BUNDLE_FRESHNESS_NOTICED=""
  _bf_stub_applied_rev="aaaaaaaa"
  _bf_stub_head_rev="aaaaaaaa"
  warn_if_bundle_predates_tree
  if [ "${#_bf_notices[@]}" -eq 0 ]; then
    assert_pass "no notice when the deployed revision matches HEAD"
  else
    assert_fail "no notice when the deployed revision matches HEAD" "got: ${_bf_notices[*]}"
  fi
}

_case_warns_when_bundle_is_stale() {
  _bf_notices=()
  _NUCLEUS_BUNDLE_FRESHNESS_NOTICED=""
  _bf_stub_applied_rev="aaaaaaaa"
  _bf_stub_head_rev="bbbbbbbb"
  warn_if_bundle_predates_tree
  if [ "${#_bf_notices[@]}" -eq 1 ]; then
    assert_pass "one notice when the deployed revision trails HEAD"
  else
    assert_fail "one notice when the deployed revision trails HEAD" "got ${#_bf_notices[@]} notices"
  fi
}

# A host that never applied has no history, and that must stay silent rather than
# inventing a revision or failing the pipeline. The stub seam treats a set value
# (even empty) as authoritative, so an explicit empty applied rev means "no history".
_case_silent_when_no_history_is_recorded() {
  _bf_notices=()
  _NUCLEUS_BUNDLE_FRESHNESS_NOTICED=""
  _bf_stub_applied_rev=""
  _bf_stub_head_rev="bbbbbbbb"
  warn_if_bundle_predates_tree
  if [ "${#_bf_notices[@]}" -eq 0 ]; then
    assert_pass "no notice when no apply history exists"
  else
    assert_fail "no notice when no apply history exists" "got: ${_bf_notices[*]}"
  fi
}

_case_notices_only_once_per_process() {
  _bf_notices=()
  _NUCLEUS_BUNDLE_FRESHNESS_NOTICED=""
  _bf_stub_applied_rev="aaaaaaaa"
  _bf_stub_head_rev="bbbbbbbb"
  warn_if_bundle_predates_tree
  warn_if_bundle_predates_tree
  if [ "${#_bf_notices[@]}" -eq 1 ]; then
    assert_pass "stale bundle notice emits only once per process"
  else
    assert_fail "stale bundle notice emits only once per process" "got ${#_bf_notices[@]} notices"
  fi
}

_case_silent_when_revisions_match
_case_warns_when_bundle_is_stale
_case_silent_when_no_history_is_recorded
_case_notices_only_once_per_process
finish_tests
