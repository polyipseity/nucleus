#!/usr/bin/env bash
# Test: harness-approval.sh request/response contract, a blocking harness hook
# must get exactly one of allow|deny|ask on stdout, in every path, and must exit
# 0 even when the broker is unreachable.
#
# The Hermes CLI is replaced by a recording stub so the suite never sends
# anything; the /harness approve|deny side is simulated by writing the same
# response file the plugin writes. The source matrix itself, including the prompt
# source's terminal, is covered by harness-approval-sources-tests.sh; the cases
# here drive the hermes source only, so no case can block on a real terminal.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

APPROVAL="$SCRIPT_DIR/../../src/scripts/notify/harness-approval.sh"

require_command mktemp "temporary directories for the recording stub"
require_command find "locating the harness-bridge state directory"

ensure_safe_rm_env

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Recording stub, mirroring harness-notify-tests.sh: proves the request was
# announced on the configured channel without talking to Hermes.
mkdir -p "$TMPDIR_ROOT/bin"
# One write per invocation: the suite polls this log while harness-approval runs in
# the background, so a reader must never observe an announcement whose body has
# not been appended yet.
cat >"$TMPDIR_ROOT/bin/hermes" <<'STUB'
#!/usr/bin/env bash
_record='ARGV'
for _arg in "$@"; do _record="$_record"$'\037'"$_arg"; done
_record="$_record"$'\n'"BODY"$'\037'"$(cat)"
printf '%s\n' "$_record" >>"$HARNESS_APPROVAL_LOG"
STUB
chmod +x "$TMPDIR_ROOT/bin/hermes"
export HARNESS_APPROVAL_LOG="$TMPDIR_ROOT/hermes.log"
: >"$HARNESS_APPROVAL_LOG"

write_config() {
  mkdir -p "$TMPDIR_ROOT/home/.local/state/nucleus"
  printf '%s\n' "$1" >"$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
}

# Every test that expects a request announced names the hermes source explicitly,
# so the prompt source and its terminal are out of the picture.
write_config_brokering() {
  write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30}}}'
}

# A request left behind by an earlier test would make a "nothing was brokered"
# assertion pass for the wrong reason.
pending_requests() {
  local _state
  _state="$(find_state)"
  [ -n "$_state" ] || return 0
  find "$_state/requests" -name '*.json' -print -quit 2>/dev/null
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
  # The request file is written before the notification is sent, so a reader that
  # looks at the stub log right after wait_for_request can beat the sender. The
  # stub appends a whole record in one write, so a non-empty log is a complete
  # announcement.
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

test_audit_log_records_the_decision() {
  write_config '{"harness-notify":{"enable":false}}'
  HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" copilot runInTerminal "rm -rf build" 5 >/dev/null
  local _log
  _log="$(find "$TMPDIR_ROOT/home" -name harness-bridge.log -print -quit 2>/dev/null)"
  if [ -n "$_log" ] && grep -qF 'copilot' "$_log" && grep -qF 'ask' "$_log"; then
    assert_pass "every approval decision is recorded in the audit log"
  else
    assert_fail "audit" "log=$_log"
  fi
}

test_remote_allow() {
  write_config_brokering
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
  write_config_brokering
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
  write_config_brokering
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

test_unwritable_state_answers_ask() {
  # A USER root that cannot be written must not leave the harness without a
  # document: Copilot reads an unanswered PreToolUse hook as a denial, so the
  # failure has to come back as `ask` and let the harness prompt locally.
  #
  # The state directory lives under the platform's USER root, so the unwritable
  # level has to be the root's own parent: on macOS `<home>/Library/Application
  # Support`, elsewhere `<home>/.local/share`. Sealing only `<home>` leaves the
  # script free to create the root on a host whose root is not nested under it,
  # and the wait it then takes is the real remote-approval timeout.
  local _ro_home="$TMPDIR_ROOT/ro-home"
  local _ro_parent
  _ro_parent="$(dirname "$(user_root_for_home "$_ro_home")")"
  mkdir -p "$_ro_home/.local/state/nucleus" "$_ro_parent"
  printf '%s\n' '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30}}}' \
    >"$_ro_home/.local/state/nucleus/config.json"
  chmod 500 "$_ro_home" "$_ro_parent"
  : >"$HARNESS_APPROVAL_LOG"
  local _rc=0
  local _out=""
  local _start=$SECONDS
  _out="$(HOME="$_ro_home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" pi bash "rm -rf build" 30)" || _rc=$?
  local _elapsed=$((SECONDS - _start))
  local _residue
  _residue="$(find "$TMPDIR_ROOT" -name '*.tmp' -print -quit 2>/dev/null)"
  chmod 700 "$_ro_home" "$_ro_parent"
  if [ "$_rc" -eq 0 ] && [ "$_out" = "ask" ] && [ "$_elapsed" -lt 5 ] &&
    [ -z "$_residue" ] && [ ! -s "$HARNESS_APPROVAL_LOG" ]; then
    assert_pass "an unwritable state directory answers ask at once"
  else
    assert_fail "unwritable-state" "rc=$_rc out=$_out elapsed=${_elapsed}s residue=$_residue log=$(cat "$HARNESS_APPROVAL_LOG")"
  fi
}

test_unreadable_config_answers_ask() {
  # An unreadable config is not a licence to die: this script must always print a
  # decision, and the .ps1 twin reaches its neutral answer through `catch`.
  write_config_brokering
  chmod 000 "$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
  : >"$HARNESS_APPROVAL_LOG"
  local _rc=0
  local _out=""
  _out="$(HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" pi bash "rm -rf build" 30 2>/dev/null)" || _rc=$?
  chmod 600 "$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
  if [ "$_rc" -eq 0 ] && [ "$_out" = "ask" ] && [ -z "$(pending_requests)" ] &&
    [ ! -s "$HARNESS_APPROVAL_LOG" ]; then
    assert_pass "an unreadable config answers ask without brokering"
  else
    assert_fail "unreadable-config" "rc=$_rc out=$_out requests=$(pending_requests) log=$(cat "$HARNESS_APPROVAL_LOG")"
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

test_approval_disabled_asks_without_request() {
  write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":[]}}'
  : >"$HARNESS_APPROVAL_LOG"
  local _rc=0
  local _out=""
  local _start=$SECONDS
  _out="$(HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$APPROVAL" pi bash "rm -rf build" 30)" || _rc=$?
  local _elapsed=$((SECONDS - _start))
  if [ "$_rc" -eq 0 ] && [ "$_out" = "ask" ] && [ "$_elapsed" -lt 5 ] &&
    [ ! -s "$HARNESS_APPROVAL_LOG" ] && [ -z "$(pending_requests)" ]; then
    assert_pass "an empty source list answers ask at once without notifying"
  else
    assert_fail "approval-off" "rc=$_rc out=$_out elapsed=${_elapsed}s log=$(cat "$HARNESS_APPROVAL_LOG")"
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
  write_config_brokering
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
  # The publish goes through a temporary name, so the announced request must be
  # the only file the glob can see.
  local _residue
  _residue="$(find "$(dirname -- "$_request")" -name '*.tmp' -print -quit 2>/dev/null)"
  if grep -qF 'approval needed' <<<"$_log" &&
    grep -qF "/harness approve $_id" <<<"$_log" &&
    grep -qF 'rm -rf build' <<<"$_log" &&
    [ -z "$_residue" ]; then
    assert_pass "the request is published whole and the notification names the action and its id"
  else
    assert_fail "announce" "log: $_log residue: $_residue"
  fi
}

test_request_file_carries_the_action() {
  write_config_brokering
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
test_unwritable_state_answers_ask
test_unreadable_config_answers_ask
test_disabled_bridge_asks_without_request
test_approval_disabled_asks_without_request
test_missing_arguments_asks
test_request_is_announced
test_request_file_carries_the_action
test_audit_log_records_the_decision

finish_tests
