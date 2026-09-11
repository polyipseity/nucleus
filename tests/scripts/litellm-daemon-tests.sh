#!/usr/bin/env bash
# Tests for src/scripts/services/litellm-daemon.sh argument handling.
#
# Two defects this pins:
#   1. the logging-config flag was silently dropped when the file was absent (no
#      message, degraded logging);
#   2. the flag was assembled into a string and expanded unquoted, so the macOS
#      path's space split it into a truncated value plus a stray positional.
#
# Run with: bash tests/scripts/litellm-daemon-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/src/scripts/services/litellm-daemon.sh"
readonly DAEMON

# Build a stub `litellm` that records its argv, one element per line, so a
# word-split argument is observable as two lines instead of one.
make_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/litellm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$LITELLM_TEST_ARGS_FILE"
STUB
  chmod +x "$dir/litellm"
}

# run_daemon <log-config-value|UNSET> <wait-seconds> <args-file> → prints rc
run_daemon() {
  local log_config="$1" wait_seconds="$2" args_file="$3" rc=0
  local stub_dir="${args_file}.stub"
  make_stub "$stub_dir"
  : >"$args_file"
  if [ "$log_config" = "UNSET" ]; then
    PATH="$stub_dir:$PATH" \
      LITELLM_TEST_ARGS_FILE="$args_file" \
      LITELLM_REDIS_POLL_TICKS=0 \
      LITELLM_LOG_CONFIG_WAIT_SECONDS="$wait_seconds" \
      bash "$DAEMON" "$CONFIG_PATH" 60 >"${args_file}.out" 2>&1 || rc=$?
  else
    PATH="$stub_dir:$PATH" \
      LITELLM_TEST_ARGS_FILE="$args_file" \
      LITELLM_REDIS_POLL_TICKS=0 \
      LITELLM_LOG_CONFIG="$log_config" \
      LITELLM_LOG_CONFIG_WAIT_SECONDS="$wait_seconds" \
      bash "$DAEMON" "$CONFIG_PATH" 60 >"${args_file}.out" 2>&1 || rc=$?
  fi
  printf '%s\n' "$rc"
}

test_log_config_with_space_stays_one_argument() {
  local tmp rc
  tmp="$(mktemp -d)"
  CONFIG_PATH="$tmp/litellm config.yml"
  : >"$CONFIG_PATH"
  local log_config="$tmp/dir with space/logging config.py"
  mkdir -p "$(dirname "$log_config")"
  : >"$log_config"
  rc="$(run_daemon "$log_config" 0 "$tmp/args")"
  if [ "$rc" -ne 0 ]; then
    assert_fail "a logging config path containing spaces is passed as one argument" "rc=$rc output=[$(cat "$tmp/args.out")]"
  elif ! grep -qxF -- "--log_config" "$tmp/args"; then
    assert_fail "a logging config path containing spaces is passed as one argument" "no --log_config in argv: [$(tr '\n' '|' <"$tmp/args")]"
  elif ! grep -qxF -- "$log_config" "$tmp/args"; then
    assert_fail "a logging config path containing spaces is passed as one argument" "path was split or truncated: [$(tr '\n' '|' <"$tmp/args")]"
  elif ! grep -qxF -- "$CONFIG_PATH" "$tmp/args"; then
    assert_fail "a logging config path containing spaces is passed as one argument" "--config path missing from argv"
  else
    assert_pass "a logging config path containing spaces is passed as one argument"
  fi
  rm -rf "$tmp"
}

test_missing_log_config_is_a_hard_error() {
  local tmp rc
  tmp="$(mktemp -d)"
  CONFIG_PATH="$tmp/litellm-config.yml"
  : >"$CONFIG_PATH"
  rc="$(run_daemon "$tmp/absent-logging-config.py" 0 "$tmp/args")"
  if [ "$rc" -ne 0 ] && grep -q "does not exist after" "$tmp/args.out" && grep -q "absent-logging-config.py" "$tmp/args.out"; then
    assert_pass "a missing logging config hard-errors and names the path"
  else
    assert_fail "a missing logging config hard-errors and names the path" "rc=$rc output=[$(cat "$tmp/args.out")]"
  fi
  rm -rf "$tmp"
}

test_unset_log_config_omits_the_flag() {
  local tmp rc
  tmp="$(mktemp -d)"
  CONFIG_PATH="$tmp/litellm-config.yml"
  : >"$CONFIG_PATH"
  rc="$(run_daemon UNSET 0 "$tmp/args")"
  if [ "$rc" -ne 0 ]; then
    assert_fail "an unset logging config starts litellm without --log_config" "rc=$rc output=[$(cat "$tmp/args.out")]"
  elif grep -qxF -- "--log_config" "$tmp/args"; then
    assert_fail "an unset logging config starts litellm without --log_config" "--log_config present in argv"
  elif ! grep -qxF -- "$CONFIG_PATH" "$tmp/args"; then
    assert_fail "an unset logging config starts litellm without --log_config" "--config path missing from argv"
  else
    assert_pass "an unset logging config starts litellm without --log_config"
  fi
  rm -rf "$tmp"
}

test_log_config_with_space_stays_one_argument
test_missing_log_config_is_a_hard_error
test_unset_log_config_omits_the_flag
finish_tests
