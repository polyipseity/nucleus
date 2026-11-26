#!/usr/bin/env bash
# Tests for nucleus-utils nested harness dispatch (Slice A, Task A1).
# Exercises the real scripts/utils.sh entry point as a subprocess so the
# dispatch, help text, and verb routing are covered behaviorally.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

UTILS_SH="$SCRIPT_DIR/../../scripts/utils.sh"

require_command jq "utils harness tests need jq"

# Run utils with a clean PATH that still has required tools but no nucleus-utils
# side effects. Keep repo root stable for scripts that derive it.
run_utils_capture() {
  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  /run/current-system/sw/bin/bash "$UTILS_SH" "$@" >"$out" 2>"$err" || rc=$?
  printf '%s\t%s\t%s\n' "$rc" "$out" "$err"
}

section 1 "bare harness invocation"

test_bare_harness_lists_verbs_and_exits_0() {
  local rc out err
  IFS=$'\t' read -r rc out err < <(run_utils_capture harness)
  if [ "$rc" -eq 0 ] &&
    grep -q 'send-notification' "$out" &&
    grep -q 'decide-call' "$out" &&
    grep -q 'request-approval' "$out" &&
    grep -q 'continue-turn' "$out" &&
    grep -q 'report-sandbox' "$out" &&
    grep -q 'check-deletion' "$out" &&
    grep -q 'merge-models' "$out"; then
    assert_pass "bare harness lists verbs and exits 0"
  else
    assert_fail "bare harness lists verbs and exits 0" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

test_harness_help_lists_verbs_and_exits_0() {
  local rc out err
  IFS=$'\t' read -r rc out err < <(run_utils_capture harness --help)
  if [ "$rc" -eq 0 ] &&
    grep -q 'send-notification' "$out" &&
    grep -q 'merge-models' "$out"; then
    assert_pass "harness --help lists verbs and exits 0"
  else
    assert_fail "harness --help lists verbs and exits 0" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

test_unknown_harness_verb_is_hard_error() {
  local rc out err
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  /run/current-system/sw/bin/bash "$UTILS_SH" harness no-such-verb >"$out" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ] &&
    grep -qi 'unknown' "$out" "$err" &&
    grep -q 'send-notification' "$out" "$err" &&
    grep -q 'merge-models' "$out" "$err"; then
    assert_pass "unknown harness verb exits non-zero and lists valid verbs"
  else
    assert_fail "unknown harness verb exits non-zero and lists valid verbs" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

section 2 "verb routing"

# report-sandbox is implemented in utils.sh itself; exercise it with an
# isolated HOME so it does not touch real state.
test_report_sandbox_reaches_sandbox_context_implementation() {
  local home rc out err
  home="$(mktemp -d)"
  mkdir -p "$home/.local/share/nucleus/state/harness-bridge"
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  env -u SANDBOX_RUNTIME HOME="$home" /run/current-system/sw/bin/bash "$UTILS_SH" harness report-sandbox pi --format text --session-id s1 >"$out" 2>"$err" || rc=$?
  local record_linux record_macos found
  record_linux="$home/.local/share/nucleus/state/harness-bridge/sandbox/pi.json"
  record_macos="$home/Library/Application Support/nucleus/state/harness-bridge/sandbox/pi.json"
  found=""
  if [ -f "$record_linux" ]; then found="$record_linux"; fi
  if [ -f "$record_macos" ]; then found="$record_macos"; fi
  if [ "$rc" -eq 0 ] && [ -n "$found" ] && jq -e '.sessions.s1.state == "unsandboxed"' "$found" >/dev/null 2>&1; then
    assert_pass "report-sandbox reaches sandbox-context implementation"
  else
    assert_fail "report-sandbox reaches sandbox-context implementation" "rc=$rc found=$found out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -rf "$home" "$out" "$err"
}

# check-deletion routes to the safe-delete filter. Use an obviously safe
# command; the hook protocol returns a decision document and exit 0.
test_check_deletion_reaches_safe_delete_implementation() {
  local rc out err
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  printf '%s' '{"tool_input":{"command":"echo hi"}}' | /run/current-system/sw/bin/bash "$UTILS_SH" harness check-deletion --hook >"$out" 2>"$err" || rc=$?
  # hook mode: allow verdict exits 0 with no stdout; deny exits 2 with stderr.
  if [ "$rc" -eq 0 ]; then
    assert_pass "check-deletion reaches safe-delete implementation"
  else
    assert_fail "check-deletion reaches safe-delete implementation" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

# send-notification/decide-call/request-approval/continue-turn dispatch to
# current notify script paths (A1 compatibility contract). We assert routing
# by observing the scripts' own usage/error behavior with missing args,
# which proves the target implementation was reached.
test_send_notification_reaches_implementation() {
  local rc out err
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  /run/current-system/sw/bin/bash "$UTILS_SH" harness send-notification >"$out" 2>"$err" || rc=$?
  # harness-notify.sh exits 0 but warns on missing args
  if grep -qi 'harness-notify\|usage' "$out" "$err"; then
    assert_pass "send-notification reaches harness-notify implementation"
  else
    assert_fail "send-notification reaches harness-notify implementation" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

test_decide_call_reaches_implementation() {
  local rc out err
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  printf '{}' | /run/current-system/sw/bin/bash "$UTILS_SH" harness decide-call cursor >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '"permission"' "$out"; then
    assert_pass "decide-call reaches harness-filter implementation"
  else
    assert_fail "decide-call reaches harness-filter implementation" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

test_request_approval_reaches_implementation() {
  local rc out err home
  home="$(mktemp -d)"
  mkdir -p "$home/.local/state/nucleus"
  printf '%s\n' '{"harness-notify":{"enable":false}}' >"$home/.local/state/nucleus/config.json"
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  HOME="$home" /run/current-system/sw/bin/bash "$UTILS_SH" harness request-approval cursor bash ls 0 >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 0 ] && grep -Eq '"permission"|"hookSpecificOutput"|allow|deny|ask' "$out"; then
    assert_pass "request-approval reaches harness-approval implementation"
  else
    assert_fail "request-approval reaches harness-approval implementation" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -rf "$home" "$out" "$err"
}

test_continue_turn_reaches_implementation() {
  local rc out err home
  home="$(mktemp -d)"
  mkdir -p "$home/.local/state/nucleus"
  printf '%s\n' '{"harness-notify":{"enable":false}}' >"$home/.local/state/nucleus/config.json"
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  HOME="$home" /run/current-system/sw/bin/bash "$UTILS_SH" harness continue-turn cursor >"$out" 2>"$err" || rc=$?
  # cursor with no queued prompt returns {}
  if [ "$rc" -eq 0 ] && grep -Eq '^\{\}|^\{\s*\}$' "$out"; then
    assert_pass "continue-turn reaches harness-drive implementation"
  else
    assert_fail "continue-turn reaches harness-drive implementation" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -rf "$home" "$out" "$err"
}

test_merge_models_is_clear_not_implemented_error() {
  local rc out err
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  /run/current-system/sw/bin/bash "$UTILS_SH" harness merge-models --check >"$out" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qi 'not implemented' "$out" "$err"; then
    assert_pass "merge-models fails clearly as not implemented"
  else
    assert_fail "merge-models fails clearly as not implemented" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

test_legacy_top_level_alias_dispatches() {
  local rc out err
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  NUCLEUS_NOTIFY_DRY_RUN=1 /run/current-system/sw/bin/bash "$UTILS_SH" harness-notify pi 'done' 'hello' >"$out" 2>"$err" || rc=$?
  # harness-notify dry-run emits nothing; contract is exit 0 and no hard error.
  if [ "$rc" -eq 0 ] && ! grep -qi 'error\|unknown harness' "$out" "$err"; then
    assert_pass "legacy top-level harness-notify alias dispatches"
  else
    assert_fail "legacy top-level harness-notify alias dispatches" "rc=$rc out=$(cat "$out") err=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

test_bare_harness_lists_verbs_and_exits_0
test_harness_help_lists_verbs_and_exits_0
test_unknown_harness_verb_is_hard_error
test_report_sandbox_reaches_sandbox_context_implementation
test_check_deletion_reaches_safe_delete_implementation
test_send_notification_reaches_implementation
test_decide_call_reaches_implementation
test_request_approval_reaches_implementation
test_continue_turn_reaches_implementation
test_merge_models_is_clear_not_implemented_error
test_legacy_top_level_alias_dispatches

finish_tests
