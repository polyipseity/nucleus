#!/usr/bin/env bash
# Test: every harness-bridge decision lands in the shared nucleus-logs audit trail.
#
# One case per event kind, driven through the real entry points: an approval
# answered over the Hermes file protocol, a notification, a filter verdict in
# both directions, and a review label attached to a decision id. The last case
# proves the contract that matters most to a hook: a log that cannot be written
# still leaves exactly one decision document and exit 0.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT

APPROVAL="$REPO_ROOT/src/scripts/notify/harness-approval.sh"
NOTIFY="$REPO_ROOT/src/scripts/notify/harness-notify.sh"
RUNNER="$REPO_ROOT/src/scripts/notify/harness-filter.sh"
LOGS="$REPO_ROOT/scripts/logs.sh"
readonly APPROVAL NOTIFY RUNNER LOGS

require_command mktemp "temporary directories for the home, the stub, and the log root"
require_command jq "the events are asserted as JSON"

ensure_safe_rm_env

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

LOG_DIR="$TMPDIR_ROOT/logs"
AUDIT="$LOG_DIR/harness.log"
export NUCLEUS_LOG_DIR="$LOG_DIR"

# Recording stub, so the notification half never talks to Hermes.
mkdir -p "$TMPDIR_ROOT/bin"
cat >"$TMPDIR_ROOT/bin/hermes" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV'
  for _arg in "$@"; do printf '\037%s' "$_arg"; done
  printf '\n'
  cat >/dev/null
} >>"$HARNESS_LOGS_LOG"
STUB
chmod +x "$TMPDIR_ROOT/bin/hermes"
HARNESS_LOGS_LOG="$TMPDIR_ROOT/hermes.log"
export HARNESS_LOGS_LOG
: >"$HARNESS_LOGS_LOG"

reset_audit() {
  mkdir -p "$LOG_DIR"
  : >"$AUDIT"
}

# Events of one kind, as a compact JSON array.
events_of() { # <kind>
  jq -sc --arg kind "$1" 'map(select(.kind == $kind))' "$AUDIT"
}

# One field of the single event of a kind; empty when the count is not one.
only_event_field() { # <kind> <field>
  local _events=""
  _events="$(events_of "$1")"
  if [ "$(jq 'length' <<<"$_events")" != "1" ]; then
    printf 'expected exactly one %s event, got %s\n' "$1" "$(jq 'length' <<<"$_events")" >&2
    return 1
  fi
  jq -r --arg field "$2" '.[0][$field] | if . == null then "null" else tostring end' <<<"$_events"
}

write_config() { # <json>
  mkdir -p "$TMPDIR_ROOT/home/.local/state/nucleus"
  printf '%s\n' "$1" >"$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
}

# --- 1. an approval decision is one event ------------------------------------

write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30}}}'
reset_audit
HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
  bash "$APPROVAL" pi bash "rm -rf build" 30 >"$TMPDIR_ROOT/out" 2>"$TMPDIR_ROOT/err" &
_approval_pid=$!

_requests_dir=""
_i=0
while [ "$_i" -lt 60 ]; do
  _requests_dir="$(find "$TMPDIR_ROOT/home" -type d -name requests -print -quit 2>/dev/null)"
  _request=""
  if [ -n "$_requests_dir" ]; then
    _request="$(find "$_requests_dir" -name '*.json' -print -quit 2>/dev/null)"
  fi
  [ -n "$_request" ] && break
  sleep 0.25
  _i=$((_i + 1))
done

if [ -n "${_request:-}" ]; then
  printf '{"decision":"allow","decided_by":"test"}\n' \
    >"$(dirname "$_requests_dir")/responses/$(basename "$_request")"
  _approval_rc=0
  wait "$_approval_pid" || _approval_rc=$?
else
  kill "$_approval_pid" 2>/dev/null || true
  wait "$_approval_pid" 2>/dev/null || true
  _approval_rc=1
fi

if [ "$_approval_rc" -eq 0 ] && [ "$(cat "$TMPDIR_ROOT/out")" = "allow" ]; then
  assert_pass "an answered approval prints the decision"
else
  assert_fail "approval document" "rc=$_approval_rc out=$(cat "$TMPDIR_ROOT/out") err=$(cat "$TMPDIR_ROOT/err")"
fi

if [ "$(events_of approval | jq 'length')" = "1" ] &&
  [ "$(only_event_field approval decision)" = "allow" ] &&
  [ "$(only_event_field approval source)" = "hermes" ] &&
  [ "$(only_event_field approval filter)" = "null" ] &&
  [ "$(only_event_field approval rule)" = "null" ]; then
  assert_pass "one approval decision writes exactly one event with its source"
else
  assert_fail "approval event" "$(cat "$AUDIT" 2>/dev/null)"
fi

# --- 2. a notification is a notify event -------------------------------------

write_config '{"harness-notify":{"channels":["telegram"]}}'
reset_audit
HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
  bash "$NOTIFY" pi "done" "turn finished" >/dev/null 2>&1
if [ "$(only_event_field notify harness)" = "pi" ] &&
  [ "$(only_event_field notify summary)" = "finished: turn finished" ]; then
  assert_pass "a notification writes one kind=notify event"
else
  assert_fail "notify event" "$(cat "$AUDIT" 2>/dev/null)"
fi

# --- 3. filter verdicts, including allow ------------------------------------

write_config '{"harness-approval":{"sources":[]}}'
reset_audit
printf '%s' '{"command":"/bin/rm -rf x"}' |
  HOME="$TMPDIR_ROOT/home" bash "$RUNNER" pi >/dev/null 2>&1
printf '%s' '{"command":"ls -la"}' |
  HOME="$TMPDIR_ROOT/home" bash "$RUNNER" pi >/dev/null 2>&1
_deny="$(jq -c 'map(select(.decision == "deny")) | .[0] // {}' <<<"$(events_of filter)")"
_allow="$(jq -c 'map(select(.decision == "allow")) | .[0] // {}' <<<"$(events_of filter)")"
if [ "$(jq -r '.filter' <<<"$_deny")" = "safe-delete" ] &&
  [ "$(jq -r '.rule' <<<"$_deny")" = "native-path" ] &&
  [ "$(jq -r '.source' <<<"$_deny")" = "filter" ] &&
  [ "$(jq -r '.decision' <<<"$_allow")" = "allow" ]; then
  assert_pass "a filter verdict writes kind=filter with its id and rule, allow included"
else
  assert_fail "filter events" "$(cat "$AUDIT" 2>/dev/null)"
fi

if [ "$(events_of filter | jq 'length')" = "2" ]; then
  assert_pass "one filter run writes exactly one filter event"
else
  assert_fail "filter event count" "$(cat "$AUDIT" 2>/dev/null)"
fi

# --- 4. a review label is visible through the app ---------------------------

_label_id="$(events_of filter | jq -r '.[0].id // ""')"
if [ -n "$_label_id" ] && [ "$_label_id" != "null" ] &&
  bash "$LOGS" label "$_label_id" false-allow --note "allowed a deletion" >/dev/null; then
  _shown="$(bash "$LOGS" show harness --json)"
  if jq -e --arg id "$_label_id" '
      any(.[]; .kind == "label" and .id == $id and .verdict == "false-allow")
    ' <<<"$_shown" >/dev/null; then
    assert_pass "a review label lands in the same log and show --json reports it"
  else
    assert_fail "label visible" "$_shown"
  fi
else
  assert_fail "label append" "id=$_label_id $(cat "$AUDIT" 2>/dev/null)"
fi

# --- 5. a failed log write keeps the document -------------------------------

# A regular file where the log root belongs makes every append fail, which is the
# only way to prove the hook still answers.
printf 'not a directory\n' >"$TMPDIR_ROOT/blocked"
NUCLEUS_LOG_DIR="$TMPDIR_ROOT/blocked/logs"
reset_audit
_rc=0
_out="$(printf '%s' '{"command":"/bin/rm -rf x"}' |
  HOME="$TMPDIR_ROOT/home" NUCLEUS_LOG_DIR="$TMPDIR_ROOT/blocked/logs" bash "$RUNNER" copilot 2>"$TMPDIR_ROOT/err")" || _rc=$?
if [ "$_rc" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$_out" >/dev/null 2>&1; then
  assert_pass "a failed audit write still prints one document and exits 0"
else
  assert_fail "failed write" "rc=$_rc out=$_out err=$(cat "$TMPDIR_ROOT/err")"
fi

finish_tests
