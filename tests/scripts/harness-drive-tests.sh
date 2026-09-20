#!/usr/bin/env bash
# Test: harness-drive.sh contract — the turn-end entry point announces the
# finished turn, consumes exactly one prompt queued by `/harness send`, and
# renders the continuation in the calling harness's own document shape.
#
# The Hermes CLI is replaced by a recording stub so the suite never sends
# anything; the queue is populated directly with the files the plugin writes.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

DRIVE="$SCRIPT_DIR/../../src/scripts/notify/harness-drive.sh"

require_command mktemp "temporary directories for the harness home"
require_command jq "queue payloads and expected documents"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Recording stub: proves the finished turn was announced without talking to
# Hermes.  Mirrors harness-notify-tests.sh.
mkdir -p "$TMPDIR_ROOT/bin"
cat >"$TMPDIR_ROOT/bin/hermes" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV'
  for _arg in "$@"; do printf '\037%s' "$_arg"; done
  printf '\n'
  cat >/dev/null
} >>"$HARNESS_DRIVE_LOG"
STUB
chmod +x "$TMPDIR_ROOT/bin/hermes"
export HARNESS_DRIVE_LOG="$TMPDIR_ROOT/hermes.log"
: >"$HARNESS_DRIVE_LOG"

# The user root differs per OS, so the suite mirrors derive_nucleus_user_root
# instead of assuming a platform path.
case "$(uname -s)" in
Darwin) USER_ROOT="$TMPDIR_ROOT/home/Library/Application Support/nucleus" ;;
*) USER_ROOT="$TMPDIR_ROOT/home/.local/share/nucleus" ;;
esac
COMMANDS="$USER_ROOT/state/harness-bridge/commands"

write_config() {
  mkdir -p "$TMPDIR_ROOT/home/.local/state/nucleus"
  printf '%s\n' "$1" >"$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
}

queue_prompt() {
  # Args: <harness> <file-name> <text>
  mkdir -p "$COMMANDS/$1"
  jq -cn --arg harness "$1" --arg text "$3" \
    '{id: "test", harness: $harness, text: $text, created_at: 0, source: "chat"}' \
    >"$COMMANDS/$1/$2"
}

run_drive() {
  # Args: <harness> [hook-payload]
  printf '%s' "${2-}" |
    HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" bash "$DRIVE" "${1-}"
}

test_cursor_followup_document() {
  write_config '{}'
  rm -rf "$COMMANDS"
  queue_prompt cursor 1000-aaaa.json "run the tests"
  : >"$HARNESS_DRIVE_LOG"
  local _out=""
  _out="$(run_drive cursor '{"hook_event_name":"Stop"}')" || true
  if [ "$_out" = '{"followup_message":"run the tests"}' ]; then
    assert_pass "a queued prompt becomes Cursor's followup_message document"
  else
    assert_fail "cursor-followup" "out=$_out"
  fi
}

test_copilot_stop_document() {
  write_config '{}'
  rm -rf "$COMMANDS"
  queue_prompt copilot 1000-bbbb.json "review the diff"
  local _out=""
  _out="$(run_drive copilot '{"stop_hook_active":false}')" || true
  if [ "$_out" = '{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":"review the diff"}}' ]; then
    assert_pass "a queued prompt becomes Copilot's Stop continuation document"
  else
    assert_fail "copilot-stop" "out=$_out"
  fi
}

test_stop_hook_active_does_not_suppress_delivery() {
  # The consume-once queue is the loop guard, not the harness's own
  # `stop_hook_active` flag.  A continuation turn arrives with that flag set, so
  # honouring it here would swallow exactly the prompt the relay was asked to
  # inject.
  write_config '{}'
  rm -rf "$COMMANDS"
  queue_prompt copilot 1000-ffff.json "keep going"
  local _out=""
  _out="$(run_drive copilot '{"stop_hook_active":true}')" || true
  if [ "$_out" = '{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":"keep going"}}' ]; then
    assert_pass "a payload that sets stop_hook_active still delivers the queued prompt"
  else
    assert_fail "loop-guard" "out=$_out"
  fi
}

test_turn_end_is_announced() {
  write_config '{}'
  rm -rf "$COMMANDS"
  : >"$HARNESS_DRIVE_LOG"
  run_drive cursor '{"hook_event_name":"Stop"}' >/dev/null || true
  local _log
  _log="$(cat "$HARNESS_DRIVE_LOG")"
  if grep -qF 'finished' <<<"$_log" && grep -qF '[cursor]' <<<"$_log"; then
    assert_pass "the finished turn is announced through harness-notify"
  else
    assert_fail "announce" "log: $_log"
  fi
}

test_empty_queue_renders_empty_documents() {
  write_config '{}'
  rm -rf "$COMMANDS"
  local _cursor=""
  local _copilot=""
  local _pi=""
  _cursor="$(run_drive cursor '{}')" || true
  _copilot="$(run_drive copilot '{}')" || true
  _pi="$(run_drive pi '{}')" || true
  if [ "$_cursor" = '{}' ] && [ "$_copilot" = '{}' ] && [ -z "$_pi" ]; then
    assert_pass "an empty queue prints {} for cursor and copilot, nothing for pi"
  else
    assert_fail "empty-queue" "cursor=$_cursor copilot=$_copilot pi=$_pi"
  fi
}

test_queued_prompt_is_consumed() {
  write_config '{}'
  rm -rf "$COMMANDS"
  queue_prompt cursor 1000-cccc.json "one shot"
  run_drive cursor '{}' >/dev/null || true
  local _left=""
  _left="$(find "$COMMANDS" -name '*.json' -print -quit 2>/dev/null)"
  local _out=""
  _out="$(run_drive cursor '{}')" || true
  if [ -z "$_left" ] && [ "$_out" = '{}' ]; then
    assert_pass "a consumed prompt is deleted and never delivered twice"
  else
    assert_fail "consume" "left=$_left out=$_out"
  fi
}

test_newest_prompt_wins_and_one_is_consumed() {
  write_config '{}'
  rm -rf "$COMMANDS"
  queue_prompt cursor 1000-dddd.json "older"
  queue_prompt cursor 2000-eeee.json "newer"
  local _first=""
  local _second=""
  _first="$(run_drive cursor '{}')" || true
  _second="$(run_drive cursor '{}')" || true
  if [ "$_first" = '{"followup_message":"newer"}' ] &&
    [ "$_second" = '{"followup_message":"older"}' ]; then
    assert_pass "the newest queued prompt goes first and only one is consumed per turn"
  else
    assert_fail "queue-order" "first=$_first second=$_second"
  fi
}

test_disabled_bridge_keeps_the_queue() {
  write_config '{"harness-notify":{"enable":false}}'
  rm -rf "$COMMANDS"
  queue_prompt copilot 1000-ffff.json "should stay queued"
  local _out=""
  _out="$(run_drive copilot '{}')" || true
  local _left=""
  _left="$(find "$COMMANDS" -name '*.json' -print -quit 2>/dev/null)"
  if [ "$_out" = '{}' ] && [ -n "$_left" ]; then
    assert_pass "harness-notify.enable=false injects nothing and keeps the queue"
  else
    assert_fail "disabled" "out=$_out left=$_left"
  fi
}

test_drive_disabled_notifies_but_drops_the_queue() {
  write_config '{"harness-drive":{"enable":false}}'
  rm -rf "$COMMANDS"
  queue_prompt cursor 1000-aaaa.json "first"
  queue_prompt cursor 2000-bbbb.json "second"
  : >"$HARNESS_DRIVE_LOG"
  rm -f "$USER_ROOT/logs/harness-bridge.log"
  local _out=""
  _out="$(run_drive cursor '{"hook_event_name":"Stop"}')" || true
  local _left=""
  _left="$(find "$COMMANDS" -name '*.json' -print -quit 2>/dev/null)"
  local _audit=""
  _audit="$(cat "$USER_ROOT/logs/harness-bridge.log" 2>/dev/null)" || _audit=""
  if [ "$_out" = '{}' ] && [ -z "$_left" ] &&
    grep -qF 'finished' <<<"$(cat "$HARNESS_DRIVE_LOG")" &&
    grep -qF 'dropped 2 queued prompt(s)' <<<"$_audit"; then
    assert_pass "harness-drive.enable=false still notifies and drops the queued prompts"
  else
    assert_fail "drive-off" "out=$_out left=$_left audit=$_audit"
  fi
}

test_drive_disabled_with_empty_queue_is_quiet() {
  write_config '{"harness-drive":{"enable":false}}'
  rm -rf "$COMMANDS"
  rm -f "$USER_ROOT/logs/harness-bridge.log"
  local _rc=0
  local _out=""
  _out="$(run_drive copilot '{}')" || _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_out" = '{}' ] &&
    [ ! -f "$USER_ROOT/logs/harness-bridge.log" ]; then
    assert_pass "with nothing queued the disabled drive path writes no audit entry"
  else
    assert_fail "drive-off-empty" "rc=$_rc out=$_out"
  fi
}

test_missing_arguments_exit_zero() {
  local _rc=0
  local _out=""
  _out="$(run_drive "" 2>/dev/null)" || _rc=$?
  if [ "$_rc" -eq 0 ] && [ -z "$_out" ]; then
    assert_pass "missing arguments exit 0 without a document"
  else
    assert_fail "usage" "rc=$_rc out=$_out"
  fi
}

test_cursor_followup_document
test_copilot_stop_document
test_stop_hook_active_does_not_suppress_delivery
test_turn_end_is_announced
test_empty_queue_renders_empty_documents
test_queued_prompt_is_consumed
test_newest_prompt_wins_and_one_is_consumed
test_disabled_bridge_keeps_the_queue
test_drive_disabled_notifies_but_drops_the_queue
test_drive_disabled_with_empty_queue_is_quiet
test_missing_arguments_exit_zero

finish_tests
