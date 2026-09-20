#!/usr/bin/env bash
# Test: harness-notify.sh event normalization, channel fan-out, config gating,
# stdin payload extraction, body cap, and best-effort exit status.
#
# The Hermes CLI is replaced by a recording stub on PATH so the suite asserts the
# exact delivery contract every harness hook depends on, without sending anything.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

NOTIFY="$SCRIPT_DIR/../../src/scripts/notify/harness-notify.sh"

require_command mktemp "temporary directories for the recording stub"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Recording stub: writes each invocation's argv (NUL-separated) and stdin body to
# $HARNESS_NOTIFY_LOG so assertions can inspect exactly what would be delivered.
mkdir -p "$TMPDIR_ROOT/bin"
cat >"$TMPDIR_ROOT/bin/hermes" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV'
  for _arg in "$@"; do printf '\037%s' "$_arg"; done
  printf '\n'
  printf 'BODY'
  _body="$(cat)"
  printf '\037%s\n' "$_body"
} >>"$HARNESS_NOTIFY_LOG"
STUB
chmod +x "$TMPDIR_ROOT/bin/hermes"
export HARNESS_NOTIFY_LOG="$TMPDIR_ROOT/hermes.log"

write_config() {
  mkdir -p "$TMPDIR_ROOT/home/.local/state/nucleus"
  printf '%s\n' "$1" >"$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
}

run_notify() {
  # Args: <stdin-text> <harness> <event> [text...]
  local _stdin="$1"
  shift
  printf '%s' "$_stdin" | HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$NOTIFY" "$@"
}

reset_log() { : >"$HARNESS_NOTIFY_LOG"; }

test_single_channel_delivery() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  reset_log
  local rc=0
  run_notify "" pi "done" "turn finished" || rc=$?
  local log
  log="$(cat "$HARNESS_NOTIFY_LOG")"
  if [ "$rc" -eq 0 ] &&
    printf '%s' "$log" | grep -qF $'\037send\037--to\037telegram\037--subject\037[pi] finished' &&
    printf '%s' "$log" | grep -qF $'\037--quiet' &&
    printf '%s' "$log" | grep -qF $'BODY\037turn finished'; then
    assert_pass "single channel: correct target, subject and body"
  else
    assert_fail "single-channel" "rc=$rc log: $log"
  fi
}

test_channel_fan_out() {
  write_config '{"harness-notify":{"channels":["telegram","ntfy"]}}'
  reset_log
  run_notify "" opencode approval "permission requested" || true
  local count
  count="$(grep -c '^ARGV' "$HARNESS_NOTIFY_LOG")"
  if [ "$count" -eq 2 ] &&
    grep -q $'\037--to\037ntfy' "$HARNESS_NOTIFY_LOG"; then
    assert_pass "fan-out: one delivery per configured channel"
  else
    assert_fail "fan-out" "expected 2 deliveries, log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_disabled_config_sends_nothing() {
  write_config '{"harness-notify":{"enable":false,"channels":["telegram"]}}'
  reset_log
  local rc=0
  run_notify "" pi "done" "silent" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$HARNESS_NOTIFY_LOG" ]; then
    assert_pass "harness-notify.enable=false suppresses delivery"
  else
    assert_fail "disabled" "rc=$rc log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_missing_config_uses_defaults() {
  rm -rf "$TMPDIR_ROOT/home/.local/state"
  reset_log
  local rc=0
  run_notify "" cursor "done" "no config file" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q $'\037--to\037telegram' "$HARNESS_NOTIFY_LOG"; then
    assert_pass "absent config file falls back to the declared defaults"
  else
    assert_fail "defaults" "rc=$rc log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_missing_arguments_is_non_fatal() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  reset_log
  local rc=0
  printf '' | HOME="$TMPDIR_ROOT/home" PATH="$TMPDIR_ROOT/bin:$PATH" \
    bash "$NOTIFY" pi 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$HARNESS_NOTIFY_LOG" ]; then
    assert_pass "missing arguments exit 0 (a hook must never fail the harness)"
  else
    assert_fail "usage" "rc=$rc log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_unknown_event_is_ignored() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  reset_log
  local rc=0
  run_notify "" pi bogus "x" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$HARNESS_NOTIFY_LOG" ]; then
    assert_pass "unknown event exits 0 without delivering"
  else
    assert_fail "unknown-event" "rc=$rc log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_hook_json_stdin_extracts_message() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  reset_log
  run_notify '{"message":"tool finished: bash"}' copilot "done" || true
  if grep -q $'BODY\037tool finished: bash' "$HARNESS_NOTIFY_LOG"; then
    assert_pass "hook JSON on stdin: message field becomes the body"
  else
    assert_fail "stdin-json" "log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_plain_text_stdin_is_body() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  reset_log
  run_notify 'plain hook output' vscode needs-input || true
  if grep -q $'BODY\037plain hook output' "$HARNESS_NOTIFY_LOG" &&
    grep -q $'\037[[]vscode] needs input' "$HARNESS_NOTIFY_LOG"; then
    assert_pass "plain stdin text is delivered with the event label as subject"
  else
    assert_fail "stdin-plain" "log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_body_is_capped() {
  write_config '{"harness-notify":{"channels":["telegram"],"max-chars":10}}'
  reset_log
  local long_body
  long_body="$(printf 'x%.0s' $(seq 1 50))"
  run_notify "" pi "done" "$long_body" || true
  local body
  body="$(grep '^BODY' "$HARNESS_NOTIFY_LOG" | cut -d$'\037' -f2)"
  if [ "${#body}" -eq 10 ]; then
    assert_pass "body is truncated to harness-notify.max-chars"
  else
    assert_fail "cap" "expected 10 chars, got ${#body}: $body"
  fi
}

test_missing_hermes_is_non_fatal() {
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  reset_log
  local rc=0
  # PATH deliberately excludes the stub directory.
  printf '' | HOME="$TMPDIR_ROOT/home" PATH="/usr/bin:/bin" \
    bash "$NOTIFY" pi "done" "no hermes" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$HARNESS_NOTIFY_LOG" ]; then
    assert_pass "missing hermes exits 0 (hooks must never fail the harness)"
  else
    assert_fail "missing-hermes" "rc=$rc log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_unreadable_config_is_non_fatal() {
  # An unreadable config must take the unparsable exit rather than dying under
  # `set -e`: the hook's own failure would reach the harness as an error.
  write_config '{"harness-notify":{"channels":["telegram"]}}'
  reset_log
  chmod 000 "$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
  local rc=0
  local err=""
  err="$(run_notify "" pi "done" "unreadable config" 2>&1 >/dev/null)" || rc=$?
  chmod 600 "$TMPDIR_ROOT/home/.local/state/nucleus/config.json"
  local warned=no
  case "$err" in *"could not parse nucleus config"*) warned=yes ;; esac
  if [ "$rc" -eq 0 ] && [ ! -s "$HARNESS_NOTIFY_LOG" ] && [ "$warned" = yes ]; then
    assert_pass "an unreadable config warns and sends nothing instead of dying"
  else
    assert_fail "unreadable-config" "rc=$rc warned=$warned log: $(cat "$HARNESS_NOTIFY_LOG")"
  fi
}

test_single_channel_delivery
test_channel_fan_out
test_disabled_config_sends_nothing
test_missing_config_uses_defaults
test_unreadable_config_is_non_fatal
test_missing_arguments_is_non_fatal
test_unknown_event_is_ignored
test_hook_json_stdin_extracts_message
test_plain_text_stdin_is_body
test_body_is_capped
test_missing_hermes_is_non_fatal

finish_tests
