#!/usr/bin/env bash
# Test: harness-approval.sh request/response contract — a blocking harness hook
# must get exactly one of allow|deny|ask on stdout, in every path, and must exit
# 0 even when the broker is unreachable.
#
# The Hermes CLI is replaced by a recording stub so the suite never sends
# anything; the /harness approve|deny side is simulated by writing the same
# response file the plugin writes.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

APPROVAL="$SCRIPT_DIR/../../src/scripts/notify/harness-approval.sh"

require_command mktemp "temporary directories for the recording stub"
require_command find "locating the harness-bridge state directory"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Recording stub, mirroring harness-notify-tests.sh: proves the request was
# announced on the configured channel without talking to Hermes.
mkdir -p "$TMPDIR_ROOT/bin"
cat >"$TMPDIR_ROOT/bin/hermes" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV'
  for _arg in "$@"; do printf '\037%s' "$_arg"; done
  printf '\n'
  _body="$(cat)"
  printf 'BODY\037%s\n' "$_body"
} >>"$HARNESS_APPROVAL_LOG"
STUB
chmod +x "$TMPDIR_ROOT/bin/hermes"
export HARNESS_APPROVAL_LOG="$TMPDIR_ROOT/hermes.log"
: >"$HARNESS_APPROVAL_LOG"

write_config() {
  mkdir -p "$TMPDIR_ROOT/home/.local/state/nucleus"
  printf '%s\n' "$1" >"$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
}

# The user root differs per OS, so the suite locates the state directory the
# script actually created instead of assuming a platform path.
find_state() {
  find "$TMPDIR_ROOT/home" -type d -name harness-bridge -print -quit 2>/dev/null
}

approval_pid=""

start_approval() {
  # Args: <timeout-seconds> [harness] [tool] [summary]
  HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" "${2:-pi}" "${3:-bash}" "${4:-rm -rf build}" "$1" \
    >"$TMPDIR_ROOT/out" 2>"$TMPDIR_ROOT/err" &
  approval_pid=$!
}

wait_for_request() {
  local _i=0
  local _state=""
  while [ "$_i" -lt 40 ]; do
    _state="$(find_state)"
    if [ -n "$_state" ] && [ -n "$(find "$_state/requests" -name '*.json' -print -quit 2>/dev/null)" ]; then
      find "$_state/requests" -name '*.json' -print -quit
      return 0
    fi
    sleep 0.25
    _i=$((_i + 1))
  done
  return 1
}

wait_for_announcement() {
  # The request file is written before the notification is sent, so a reader
  # that looks at the stub log right after wait_for_request can beat the sender.
  local _i=0
  while [ "$_i" -lt 40 ]; do
    if [ -s "$HARNESS_APPROVAL_LOG" ]; then
      cat "$HARNESS_APPROVAL_LOG"
      return 0
    fi
    sleep 0.25
    _i=$((_i + 1))
  done
  return 1
}

answer_request() {
  # Args: <request-file> <decision>
  local _request="$1" _decision="$2"
  local _state
  _state="$(dirname "$(dirname "$_request")")"
  printf '{"decision":"%s","decided_by":"chat"}\n' "$_decision" \
    >"$_state/responses/$(basename "$_request")"
}

wait_for_decision() {
  local _rc=0
  wait "$approval_pid" || _rc=$?
  approval_pid=""
  approval_rc="$_rc"
  approval_out="$(cat "$TMPDIR_ROOT/out")"
}

start_approval_hook() {
  # Args: <timeout-seconds> <harness> <payload>
  printf '%s' "$3" >"$TMPDIR_ROOT/hook-payload"
  HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" hook "$2" <"$TMPDIR_ROOT/hook-payload" \
    >"$TMPDIR_ROOT/out" 2>"$TMPDIR_ROOT/err" &
  approval_pid=$!
}

test_hook_mode_renders_cursor_json() {
  write_config '{"harness-notify":{"enable":false}}'
  local _rc=0
  local _out=""
  _out="$(printf '%s' '{"command":"git push --force"}' | HOME="$TMPDIR_ROOT/home" \
    PATH="$TMPDIR_ROOT/bin:$PATH" bash "$APPROVAL" hook cursor)" || _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_out" = '{"permission":"ask"}' ]; then
    assert_pass "hook mode answers Cursor with Cursor's own document"
  else
    assert_fail "hook-cursor" "rc=$_rc out=$_out"
  fi
}

test_hook_mode_renders_copilot_json() {
  write_config '{"harness-notify":{"enable":false}}'
  local _rc=0
  local _out=""
  _out="$(printf '%s' '{"tool_name":"runInTerminal","tool_input":{"command":"rm -rf /"}}' |
    HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" bash "$APPROVAL" hook copilot)" || _rc=$?
  if [ "$_rc" -eq 0 ] &&
    grep -qF '"hookEventName":"PreToolUse"' <<<"$_out" &&
    grep -qF '"permissionDecision":"ask"' <<<"$_out"; then
    assert_pass "hook mode answers Copilot with a PreToolUse decision document"
  else
    assert_fail "hook-copilot" "rc=$_rc out=$_out"
  fi
}

test_hook_mode_asks_plainly_for_unknown_harness() {
  write_config '{"harness-notify":{"enable":false}}'
  local _rc=0
  local _out=""
  _out="$(printf '%s' '{}' | HOME="$TMPDIR_ROOT/home" \
    PATH="$TMPDIR_ROOT/bin:$PATH" bash "$APPROVAL" hook opencode)" || _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_out" = 'ask' ]; then
    assert_pass "hook mode falls back to the plain decision for other harnesses"
  else
    assert_fail "hook-plain" "rc=$_rc out=$_out"
  fi
}

test_hook_mode_brokers_the_payload_command() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  : >"$HARNESS_APPROVAL_LOG"
  start_approval_hook 30 cursor '{"command":"git push --force","cwd":"/tmp"}'
  local _request
  if ! _request="$(wait_for_request)"; then
    kill "$approval_pid" 2>/dev/null
    approval_pid=""
    assert_fail "hook-broker" "no request file appeared"
    return
  fi
  local _announced
  _announced="$(wait_for_announcement || true)"
  answer_request "$_request" allow
  wait_for_decision
  if [ "$approval_rc" -eq 0 ] && [ "$approval_out" = '{"permission":"allow"}' ] &&
    grep -qF 'git push --force' <<<"$_announced"; then
    assert_pass "hook mode brokers the payload command and renders a remote allow"
  else
    assert_fail "hook-broker" "rc=$approval_rc out=$approval_out log=$_announced"
  fi
}

test_audit_log_records_the_decision() {
  write_config '{"harness-notify":{"enable":false}}'
  printf '%s' '{"tool_name":"bash","tool_input":"rm -rf build"}' |
    HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" bash "$APPROVAL" hook copilot >/dev/null
  local _log
  _log="$(find "$TMPDIR_ROOT/home" -name harness-bridge.log -print -quit 2>/dev/null)"
  if [ -n "$_log" ] && grep -qF 'copilot' "$_log" && grep -qF 'ask' "$_log"; then
    assert_pass "every hook decision is recorded in the audit log"
  else
    assert_fail "audit" "log=$_log"
  fi
}

test_remote_allow() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  start_approval 30
  local _request
  if ! _request="$(wait_for_request)"; then
    kill "$approval_pid" 2>/dev/null
    approval_pid=""
    assert_fail "allow" "no request file appeared"
    return
  fi
  answer_request "$_request" allow
  wait_for_decision
  if [ "$approval_rc" -eq 0 ] && [ "$approval_out" = "allow" ]; then
    assert_pass "a remote allow decision is printed as allow"
  else
    assert_fail "allow" "rc=$approval_rc out=$approval_out err=$(cat "$TMPDIR_ROOT/err")"
  fi
}

test_remote_deny() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  start_approval 30
  local _request
  if ! _request="$(wait_for_request)"; then
    kill "$approval_pid" 2>/dev/null
    approval_pid=""
    assert_fail "deny" "no request file appeared"
    return
  fi
  answer_request "$_request" deny
  wait_for_decision
  if [ "$approval_rc" -eq 0 ] && [ "$approval_out" = "deny" ]; then
    assert_pass "a remote deny decision is printed as deny"
  else
    assert_fail "deny" "rc=$approval_rc out=$approval_out"
  fi
}

test_timeout_asks_locally() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  start_approval 2
  wait_for_decision
  local _state
  _state="$(find_state)"
  # The request must not linger as pending: an unanswered request is not a
  # decision the user can still make.
  if [ "$approval_rc" -eq 0 ] && [ "$approval_out" = "ask" ] &&
    [ -z "$(find "$_state/requests" -name '*.json' -print -quit 2>/dev/null)" ]; then
    assert_pass "no answer within the timeout prints ask and clears the request"
  else
    assert_fail "timeout" "rc=$approval_rc out=$approval_out state=$(find "$_state" -type f)"
  fi
}

test_disabled_bridge_asks_without_request() {
  write_config '{"harness-notify":{"enable":false,"channels":["telegram"]}}'
  : >"$HARNESS_APPROVAL_LOG"
  local _rc=0
  local _out=""
  _out="$(HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" pi bash "rm -rf build" 5)" || _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_out" = "ask" ] &&
    [ ! -s "$HARNESS_APPROVAL_LOG" ]; then
    assert_pass "harness-notify.enable=false answers ask without notifying"
  else
    assert_fail "disabled" "rc=$_rc out=$_out log=$(cat "$HARNESS_APPROVAL_LOG")"
  fi
}

test_missing_arguments_asks() {
  local _rc=0
  local _out=""
  _out="$(HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" pi 2>/dev/null)" || _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_out" = "ask" ]; then
    assert_pass "missing arguments print ask and exit 0"
  else
    assert_fail "usage" "rc=$_rc out=$_out"
  fi
}

test_request_is_announced() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  : >"$HARNESS_APPROVAL_LOG"
  start_approval 30
  local _request
  if ! _request="$(wait_for_request)"; then
    kill "$approval_pid" 2>/dev/null
    approval_pid=""
    assert_fail "announce" "no request file appeared"
    return
  fi
  local _id
  _id="$(basename "$_request" .json)"
  local _log
  _log="$(wait_for_announcement || true)"
  answer_request "$_request" deny
  wait_for_decision
  if grep -qF 'approval needed' <<<"$_log" &&
    grep -qF "/harness approve $_id" <<<"$_log" &&
    grep -qF 'rm -rf build' <<<"$_log"; then
    assert_pass "the notification names the action and the request id to answer"
  else
    assert_fail "announce" "log: $_log"
  fi
}

test_request_file_carries_the_action() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  start_approval 30 cursor Shell "git push --force"
  local _request
  if ! _request="$(wait_for_request)"; then
    kill "$approval_pid" 2>/dev/null
    approval_pid=""
    assert_fail "request-shape" "no request file appeared"
    return
  fi
  local _payload
  _payload="$(cat "$_request")"
  answer_request "$_request" allow
  wait_for_decision
  if grep -qF '"harness": "cursor"' <<<"$_payload" &&
    grep -qF '"tool": "Shell"' <<<"$_payload" &&
    grep -qF '"summary": "git push --force"' <<<"$_payload"; then
    assert_pass "the request records harness, tool and summary for /harness status"
  else
    assert_fail "request-shape" "payload: $_payload"
  fi
}

test_remote_allow
test_remote_deny
test_timeout_asks_locally
test_disabled_bridge_asks_without_request
test_missing_arguments_asks
test_request_is_announced
test_request_file_carries_the_action
test_hook_mode_renders_cursor_json
test_hook_mode_renders_copilot_json
test_hook_mode_asks_plainly_for_unknown_harness
test_hook_mode_brokers_the_payload_command
test_audit_log_records_the_decision

finish_tests
