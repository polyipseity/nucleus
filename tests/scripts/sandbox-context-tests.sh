#!/usr/bin/env bash
# Tests for `nucleus-utils harness report-sandbox` (.sh twin): record format, state
# decisions, output formats, pruning, corrupt-record handling, and the config
# gate.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
UTILS_SH="$REPO_ROOT/scripts/utils.sh"

require_command jq "sandbox-context reads and writes JSON records with jq"
require_command python3 "sandbox-context computes pruning cutoffs with python3 fallback when date flags differ"

_new_home() {
  local home
  home="$(mktemp -d)"
  case "$(uname -s)" in
  Darwin) mkdir -p "$home/Library/Application Support/nucleus" ;;
  *) mkdir -p "$home/.local/share/nucleus" ;;
  esac
  mkdir -p "$home/.local/state/nucleus"
  printf '%s\n' "$home"
}

_user_root() {
  local home="$1"
  case "$(uname -s)" in
  Darwin) printf '%s\n' "$home/Library/Application Support/nucleus" ;;
  *) printf '%s\n' "$home/.local/share/nucleus" ;;
  esac
}

_record_file() {
  printf '%s\n' "$(_user_root "$1")/state/harness-bridge/sandbox/$2.json"
}

_run_sc() { # <home> <sandbox_runtime|UNSET> [args...]
  local home="$1" runtime="$2"
  shift 2
  if [ "$runtime" = "UNSET" ]; then
    env -u SANDBOX_RUNTIME HOME="$home" bash "$UTILS_SH" sandbox-context "$@"
  else
    HOME="$home" SANDBOX_RUNTIME="$runtime" bash "$UTILS_SH" sandbox-context "$@"
  fi
}

_run_sc_stdin() { # <home> <runtime|UNSET> <stdin> [args...]
  local home="$1" runtime="$2" input="$3"
  shift 3
  if [ "$runtime" = "UNSET" ]; then
    printf '%s' "$input" | env -u SANDBOX_RUNTIME HOME="$home" bash "$UTILS_SH" sandbox-context "$@"
  else
    printf '%s' "$input" | HOME="$home" SANDBOX_RUNTIME="$runtime" bash "$UTILS_SH" sandbox-context "$@"
  fi
}

_set_config() { # <home> <json>
  local home="$1"
  printf '%s\n' "$2" >"$home/.local/state/nucleus/config.json"
}

_iso_days_ago() { # <days>
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
}

_iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

SANDBOXED_BLOCK="You are inside the srt sandbox. The repo and the granted scratch paths work normally, but the fence is real: network destinations and Unix sockets are allowlisted, some paths are read-only, git config hooks and secrets are protected, and deletions land in the Trash through the safe wrapper (Finder 'Put Back' is unavailable because Apple Events are denied). If a command fails with a permission or socket error, assume the fence before assuming a bug, say what you need, and use \`pi-unrestricted\` only when the task genuinely needs the unsandboxed host."
UNSANDBOXED_BLOCK="You are outside the srt sandbox, so the full host is reachable. That is more power than the sandboxed default, so treat deletions, secrets, and network calls with extra care; the safe-delete rules still apply, and a command that worked here may be blocked in the sandbox when you switch back."

_t_unknown_sandboxed() {
  local home out rc=0 file state
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  out="$(_run_sc "$home" 1 pi --format text --session-id s1)" || rc=$?
  file="$(_record_file "$home" pi)"
  state="$(jq -r '.sessions.s1.state' "$file" 2>/dev/null || true)"
  if [ "$rc" -eq 0 ] && [ "$out" = "$SANDBOXED_BLOCK" ] && [ "$state" = "sandboxed" ]; then
    assert_pass "unknown -> sandboxed emits full sandboxed block and records state"
  else
    assert_fail "unknown -> sandboxed" "rc=$rc state=[$state] out=[$out]"
  fi
}

_t_unknown_unsandboxed() {
  local home out rc=0 file state
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  out="$(_run_sc "$home" UNSET pi --format text --session-id s1)" || rc=$?
  file="$(_record_file "$home" pi)"
  state="$(jq -r '.sessions.s1.state' "$file" 2>/dev/null || true)"
  if [ "$rc" -eq 0 ] && [ "$out" = "$UNSANDBOXED_BLOCK" ] && [ "$state" = "unsandboxed" ]; then
    assert_pass "unknown -> unsandboxed emits full unsandboxed block and records state"
  else
    assert_fail "unknown -> unsandboxed" "rc=$rc state=[$state] out=[$out]"
  fi
}

_t_transition_sandboxed_to_unsandboxed() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _run_sc "$home" 1 pi --format text --session-id s1 >/dev/null
  out="$(_run_sc "$home" UNSET pi --format text --session-id s1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Sandbox state changed: sandboxed -> unsandboxed\.' && printf '%s' "$out" | grep -q 'full host is reachable'; then
    assert_pass "sandboxed -> unsandboxed emits a change notice naming both states and consequence"
  else
    assert_fail "sandboxed -> unsandboxed transition" "rc=$rc out=[$out]"
  fi
}

_t_transition_unsandboxed_to_sandboxed() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _run_sc "$home" UNSET pi --format text --session-id s1 >/dev/null
  out="$(_run_sc "$home" 1 pi --format text --session-id s1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Sandbox state changed: unsandboxed -> sandboxed\.' && printf '%s' "$out" | grep -q 'fence is real'; then
    assert_pass "unsandboxed -> sandboxed emits a change notice naming both states and consequence"
  else
    assert_fail "unsandboxed -> sandboxed transition" "rc=$rc out=[$out]"
  fi
}

_t_unchanged_no_output_no_rewrite() {
  local home out rc=0 file before after
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _run_sc "$home" 1 pi --format text --session-id s1 >/dev/null
  file="$(_record_file "$home" pi)"
  before="$(cat "$file")"
  out="$(_run_sc "$home" 1 pi --format text --session-id s1)" || rc=$?
  after="$(cat "$file")"
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$before" = "$after" ]; then
    assert_pass "unchanged state emits nothing and does not rewrite the record"
  else
    assert_fail "unchanged state" "rc=$rc out=[$out] changed=$([ "$before" = "$after" ] && echo no || echo yes)"
  fi
}

_t_corrupt_file_reported_treated_unknown() {
  local home out err rc=0 file state
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  file="$(_record_file "$home" pi)"
  mkdir -p "$(dirname "$file")"
  printf '{not json' >"$file"
  err="$(mktemp)"
  out="$(_run_sc "$home" 1 pi --format text --session-id s1 2>"$err")" || rc=$?
  state="$(jq -r '.sessions.s1.state' "$file" 2>/dev/null || true)"
  if [ "$rc" -eq 0 ] && grep -qi 'corrupt\|unreadable' "$err" && [ "$out" = "$SANDBOXED_BLOCK" ] && [ "$state" = "sandboxed" ]; then
    assert_pass "corrupt record is reported, treated as unknown, and replaced with a valid observation"
  else
    assert_fail "corrupt record handling" "rc=$rc state=[$state] err=[$(cat "$err")] out=[$out]"
  fi
  rm -f "$err"
}

_t_pruning_and_cap() {
  local home out rc=0 file count has_old
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  file="$(_record_file "$home" pi)"
  mkdir -p "$(dirname "$file")"
  local old now
  old="$(_iso_days_ago 40)"
  now="$(_iso_now)"
  python3 - "$file" "$old" "$now" <<'PY'
import json, sys
path, old, now = sys.argv[1], sys.argv[2], sys.argv[3]
sessions = {"old-session": {"state": "sandboxed", "evidence": "e", "observedAt": old}}
for i in range(60):
    sessions[f"s{i:02d}"] = {"state": "sandboxed", "evidence": "e", "observedAt": now}
json.dump({"version": 1, "sessions": sessions}, open(path, "w"))
PY
  out="$(_run_sc "$home" 1 pi --format text --session-id new-session)" || rc=$?
  count="$(jq '.sessions | length' "$file" 2>/dev/null || echo 0)"
  has_old="$(jq -r '.sessions["old-session"].state // "missing"' "$file" 2>/dev/null || echo missing)"
  if [ "$rc" -eq 0 ] && [ "$out" = "$SANDBOXED_BLOCK" ] && [ "$count" -le 50 ] && [ "$has_old" = "missing" ] && jq -e '.sessions["new-session"].state == "sandboxed"' "$file" >/dev/null 2>&1; then
    assert_pass "pruning drops sessions unobserved for 30 days and caps the map at 50"
  else
    assert_fail "pruning and cap" "rc=$rc count=[$count] has_old=[$has_old] out=[$out]"
  fi
}

_t_disabled_gate_records_but_no_injection() {
  local home out rc=0 file state before after
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _set_config "$home" '{"sandbox-context":{"inject-on-change":false}}'
  out="$(_run_sc "$home" 1 pi --format text --session-id s1)" || rc=$?
  file="$(_record_file "$home" pi)"
  state="$(jq -r '.sessions.s1.state' "$file" 2>/dev/null || true)"
  if [ "$rc" -ne 0 ] || [ -n "$out" ] || [ "$state" != "sandboxed" ]; then
    assert_fail "disabled gate first observation" "rc=$rc out=[$out] state=[$state]"
    return
  fi
  before="$(cat "$file")"
  out="$(_run_sc "$home" UNSET pi --format text --session-id s1)" || rc=$?
  state="$(jq -r '.sessions.s1.state' "$file" 2>/dev/null || true)"
  after="$(cat "$file")"
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$state" = "unsandboxed" ] && [ "$before" != "$after" ]; then
    assert_pass "disabled gate records state advances without emitting"
  else
    assert_fail "disabled gate transition" "rc=$rc out=[$out] state=[$state]"
  fi
}

_t_claude_format() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  out="$(_run_sc "$home" 1 claude --format claude --session-id s1)" || rc=$?
  if [ "$rc" -eq 0 ] && jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.additionalContext | contains("inside the srt sandbox"))' <<<"$out" >/dev/null 2>&1; then
    assert_pass "claude format emits UserPromptSubmit hookSpecificOutput.additionalContext"
  else
    assert_fail "claude format" "rc=$rc out=[$out]"
  fi
}

_t_check_format() {
  local home out rc=0 file
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  out="$(_run_sc "$home" 1 copilot --format check --session-id s1)" || rc=$?
  file="$(_record_file "$home" copilot)"
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && jq -e '.sessions.s1.state == "sandboxed"' "$file" >/dev/null 2>&1; then
    assert_pass "check format records without emitting"
  else
    assert_fail "check format" "rc=$rc out=[$out] file=[$(cat "$file" 2>/dev/null || true)]"
  fi
}

_t_session_id_from_payload() {
  local home out rc=0 file
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  out="$(_run_sc_stdin "$home" 1 '{"session_id":"sess-123","prompt":"hi"}' claude --format check)" || rc=$?
  file="$(_record_file "$home" claude)"
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && jq -e '.sessions["sess-123"].state == "sandboxed"' "$file" >/dev/null 2>&1; then
    assert_pass "session id is extracted from hook payload when not provided explicitly"
  else
    assert_fail "session id from payload" "rc=$rc out=[$out] file=[$(cat "$file" 2>/dev/null || true)]"
  fi
}

_t_default_session_id() {
  local home file
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _run_sc "$home" 1 pi --format check >/dev/null
  file="$(_record_file "$home" pi)"
  if jq -e '.sessions["default"].state == "sandboxed"' "$file" >/dev/null 2>&1; then
    assert_pass "missing session id uses the literal default key"
  else
    assert_fail "default session id" "file=[$(cat "$file" 2>/dev/null || true)]"
  fi
}

section 1 "unknown state emits full status and records"
_t_unknown_sandboxed
_t_unknown_unsandboxed
_t_default_session_id

section 2 "transitions and unchanged behavior"
_t_transition_sandboxed_to_unsandboxed
_t_transition_unsandboxed_to_sandboxed
_t_unchanged_no_output_no_rewrite

section 3 "corrupt records, pruning, and gate"
_t_corrupt_file_reported_treated_unknown
_t_pruning_and_cap
_t_disabled_gate_records_but_no_injection

section 4 "formats and session extraction"
_t_claude_format
_t_check_format
_t_session_id_from_payload

finish_tests
