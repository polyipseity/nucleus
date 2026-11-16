#!/usr/bin/env bash
# Tests for nucleus-apply status CLI behavior (G3 Task 7).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state
ensure_safe_rm_env

require_command jq "apply-status tests use jq"

APPLY_SH="$SCRIPT_DIR/../../src/scripts/apply.sh"

_run_status() {
  # Runs status in an isolated env rooted at $1. Remaining args passed to apply.sh.
  local root="$1"
  shift
  local out_file err_file rc_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  rc_file="$(mktemp)"
  (
    export HOME="$root/home"
    export NUCLEUS_USER_ROOT="$root/user-root"
    mkdir -p "$HOME/.local/state/nucleus" "$NUCLEUS_USER_ROOT"
    set +e
    bash "$APPLY_SH" "$@" >"$out_file" 2>"$err_file"
    printf '%s' "$?" >"$rc_file"
  )
  LAST_RC="$(cat "$rc_file")"
  LAST_OUT="$(cat "$out_file")"
  LAST_ERR="$(cat "$err_file")"
  rm -f "$out_file" "$err_file" "$rc_file"
}

_hist_path() {
  printf '%s/user-root/state/apply/history.jsonl\n' "$1"
}

_write_entry() {
  # root user result phase
  local root="$1" user="$2" result="$3" phase="$4"
  local p
  p="$(_hist_path "$root")"
  mkdir -p "$(dirname "$p")"
  jq -nc \
    --arg result "$result" \
    --arg phase "$phase" \
    --arg user "$user" \
    '{version:1,appliedAt:"2026-01-01T00:00:00.000Z",result:$result,phase:(if $phase == "null" then null else $phase end),host:"TestHost",user:$user,repoRoot:"/repo",commitHash:"abc1234",branch:"main",detachedHead:false,appliedCommitTag:null,lastTagOnBranch:"v1.0.0",hasUnstaged:false,hasStaged:false,hasUntracked:false,isDirty:false}' \
    >>"$p"
}

section 1 "missing/empty history"

_t_empty_missing() {
  local root
  root="$(mktemp -d)"
  _run_status "$root" status
  if [ "$LAST_RC" -eq 0 ] && printf '%s' "$LAST_OUT" | grep -q "No apply history yet."; then
    assert_pass "status on missing history exits 0 with humanized message"
  else
    assert_fail "status on missing history" "rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
  fi
  rm -rf "$root"
}

_t_empty_file_json() {
  local root
  root="$(mktemp -d)"
  _run_status "$root" status --json
  if [ "$LAST_RC" -eq 0 ] && printf '%s' "$LAST_OUT" | jq -e '.version == 1 and (.entries | length == 0)' >/dev/null 2>&1; then
    assert_pass "status --json on empty history returns empty entries"
  else
    assert_fail "status --json on empty history" "rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
  fi
  rm -rf "$root"
}

_t_empty_missing

_t_empty_file_json

section 2 "json shape and default count"

_t_json_latest_shape() {
  local root
  root="$(mktemp -d)"
  _write_entry "$root" "u1" "success" "null"
  _write_entry "$root" "u2" "failure" "rebuild"
  _run_status "$root" status --json
  local ok=1
  if [ "$LAST_RC" -ne 0 ]; then ok=0; fi
  if ! printf '%s' "$LAST_OUT" | jq -e '.version == 1' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$LAST_OUT" | jq -e '.entries | length == 1' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$LAST_OUT" | jq -e '.entries[0].user == "u2" and .entries[0].result == "failure" and .entries[0].phase == "rebuild"' >/dev/null 2>&1; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    assert_pass "status --json returns latest entry with versioned shape"
  else
    assert_fail "status --json latest shape" "rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
  fi
  rm -rf "$root"
}

_t_json_latest_shape

section 3 "history N newest-first and count"

_t_history_human() {
  local root
  root="$(mktemp -d)"
  _write_entry "$root" "first" "success" "null"
  _write_entry "$root" "second" "success" "null"
  _write_entry "$root" "third" "failure" "post-apply"
  _run_status "$root" status --history 2
  local ok=1
  if [ "$LAST_RC" -ne 0 ]; then ok=0; fi
  # newest-first: third appears before second, first does not appear
  if ! printf '%s' "$LAST_OUT" | grep -q "user: third"; then ok=0; fi
  if ! printf '%s' "$LAST_OUT" | grep -q "user: second"; then ok=0; fi
  if printf '%s' "$LAST_OUT" | grep -q "user: first"; then ok=0; fi
  # third block should come before second
  local third_pos second_pos
  third_pos="$(printf '%s' "$LAST_OUT" | grep -n "user: third" | head -1 | cut -d: -f1)"
  second_pos="$(printf '%s' "$LAST_OUT" | grep -n "user: second" | head -1 | cut -d: -f1)"
  if [ -z "$third_pos" ] || [ -z "$second_pos" ] || [ "$third_pos" -ge "$second_pos" ]; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    assert_pass "status --history N prints N newest records most recent first"
  else
    assert_fail "status --history N human" "rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
  fi
  rm -rf "$root"
}

_t_history_json() {
  local root
  root="$(mktemp -d)"
  _write_entry "$root" "first" "success" "null"
  _write_entry "$root" "second" "success" "null"
  _write_entry "$root" "third" "failure" "post-apply"
  _run_status "$root" status --history 2 --json
  local ok=1
  if [ "$LAST_RC" -ne 0 ]; then ok=0; fi
  if ! printf '%s' "$LAST_OUT" | jq -e '.entries | length == 2' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$LAST_OUT" | jq -e '.entries[0].user == "third" and .entries[1].user == "second"' >/dev/null 2>&1; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    assert_pass "status --history N --json returns N newest entries in order"
  else
    assert_fail "status --history N --json" "rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
  fi
  rm -rf "$root"
}

_t_history_human
_t_history_json

section 4 "corrupt line error"

_t_corrupt_line() {
  local root p
  root="$(mktemp -d)"
  p="$(_hist_path "$root")"
  mkdir -p "$(dirname "$p")"
  printf '{"version":1,"result":"success"}\nnot-json\n' >"$p"
  _run_status "$root" status
  if [ "$LAST_RC" -ne 0 ] && printf '%s\n%s' "$LAST_OUT" "$LAST_ERR" | grep -q "corrupt line 2"; then
    assert_pass "corrupt line reported naming line number with non-zero exit"
  else
    assert_fail "corrupt line error" "rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
  fi
  rm -rf "$root"
}

_t_corrupt_line

section 5 "human latest default"

_t_human_latest() {
  local root
  root="$(mktemp -d)"
  _write_entry "$root" "old" "success" "null"
  _write_entry "$root" "new" "success" "null"
  _run_status "$root" status
  if [ "$LAST_RC" -eq 0 ] && printf '%s' "$LAST_OUT" | grep -q "user: new" && ! printf '%s' "$LAST_OUT" | grep -q "user: old"; then
    assert_pass "status with no args shows newest record human-readably"
  else
    assert_fail "status default human latest" "rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
  fi
  rm -rf "$root"
}

_t_human_latest

finish_tests
