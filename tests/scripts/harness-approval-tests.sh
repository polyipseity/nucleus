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
CURSOR_GATE="$SCRIPT_DIR/../../src/users/default/cursor/hooks/approve-shell.sh"

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

run_cursor_gate() {
  # Args: <stdin-payload>  — PATH holds only the stub harness-approval plus the
  # real tools the script needs (jq, cat, printf).
  printf '%s' "$1" | PATH="$TMPDIR_ROOT/gate-bin:$PATH" bash "$CURSOR_GATE"
}

test_cursor_gate_forwards_allow() {
  mkdir -p "$TMPDIR_ROOT/gate-bin"
  cat >"$TMPDIR_ROOT/gate-bin/harness-approval" <<'STUB'
#!/usr/bin/env bash
printf 'allow\n'
STUB
  chmod +x "$TMPDIR_ROOT/gate-bin/harness-approval"
  local _out=""
  _out="$(run_cursor_gate '{"command":"git push --force","cwd":"/tmp"}')" || true
  if [ "$_out" = '{"permission":"allow"}' ]; then
    assert_pass "beforeShellExecution gate forwards an allow decision"
  else
    assert_fail "cursor-allow" "out=$_out"
  fi
}

test_cursor_gate_fails_open_to_ask() {
  mkdir -p "$TMPDIR_ROOT/gate-bin"
  rm -f "$TMPDIR_ROOT/gate-bin/harness-approval"
  local _out=""
  _out="$(run_cursor_gate '{"command":"ls"}')" || true
  if [ "$_out" = '{"permission":"ask"}' ]; then
    assert_pass "a missing broker answers ask, never allow"
  else
    assert_fail "cursor-missing-broker" "out=$_out"
  fi
}

test_cursor_gate_asks_when_payload_has_no_command() {
  mkdir -p "$TMPDIR_ROOT/gate-bin"
  cat >"$TMPDIR_ROOT/gate-bin/harness-approval" <<'STUB'
#!/usr/bin/env bash
printf 'deny\n'
STUB
  chmod +x "$TMPDIR_ROOT/gate-bin/harness-approval"
  local _out=""
  _out="$(run_cursor_gate '{"unexpected":"shape"}')" || true
  if [ "$_out" = '{"permission":"ask"}' ]; then
    assert_pass "an unrecognised payload shape asks instead of denying"
  else
    assert_fail "cursor-unknown-payload" "out=$_out"
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
  _log="$(cat "$HARNESS_APPROVAL_LOG")"
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
test_cursor_gate_forwards_allow
test_cursor_gate_fails_open_to_ask
test_cursor_gate_asks_when_payload_has_no_command

finish_tests
