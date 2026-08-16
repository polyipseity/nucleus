#!/usr/bin/env bash
# Unit tests for step-runner.sh functions in isolation.
# Covers Spec A (step IDs) and Spec B (--skip-steps).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# ---- Spec A: Step ID registration (4-arg form) ----

test_register_step_with_id() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    register_step "code-formatting" 1 "Code formatting" test_func
    echo "${_STEP_IDS[0]} ${_STEP_NUMBERS[0]} ${_STEP_NAMES[0]}"
  )
  if echo "$result" | grep -q "code-formatting 1 Code formatting"; then
    assert_pass "register_step stores id, number, name correctly"
  else
    assert_fail "register_step 4-arg" "Expected 'code-formatting 1 Code formatting', got: $result"
  fi
}

test_register_step_multiple_with_ids() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    register_step "one" 1 "One" f1
    register_step "two" 2 "Two" f2
    register_step "three" 3 "Three" f3
    echo "${_STEP_IDS[*]} ${#_STEP_NUMBERS[@]}"
  )
  if echo "$result" | grep -q "one two three 3"; then
    assert_pass "register_step accumulates multiple steps with IDs"
  else
    assert_fail "register_step multiple IDs" "Expected 'one two three 3', got: $result"
  fi
}

test_register_step_id_with_digits_errors() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "test-1-bad" 1 "Bad" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "register_step with digit in ID errors (Spec A)"
  else
    assert_fail "register_step digit ID" "Expected non-zero exit for ID containing digit, got: $exit_code"
  fi
}

test_register_step_empty_id_errors() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "" 1 "Empty" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "register_step with empty ID errors (Spec A)"
  else
    assert_fail "register_step empty ID" "Expected non-zero exit for empty ID, got: $exit_code"
  fi
}

test_register_step_duplicate_id_errors() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "dup" 1 "First" true
        register_step "dup" 2 "Second" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "register_step duplicate ID errors (Spec A)"
  else
    assert_fail "register_step dup ID" "Expected non-zero exit for duplicate ID, got: $exit_code"
  fi
}

test_register_step_duplicate_number_errors() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "first" 1 "First" true
        register_step "second" 1 "Second" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "register_step duplicate number errors (Spec A)"
  else
    assert_fail "register_step dup num" "Expected non-zero exit for duplicate number, got: $exit_code"
  fi
}

# ---- Step number derivation (3-arg form) ----

test_register_step_derives_number_from_filename() {
  local _result _num _out
  _step_runner_fake_tmp="$(mktemp -d)"
  trap 'rm -rf "$_step_runner_fake_tmp"' EXIT
  cat >"$_step_runner_fake_tmp/05-fake.sh" <<EOF
. "$REPO_ROOT/src/scripts/lib/step-runner.sh"
register_step "fake" "Fake" fake_run
fake_run() { step_number; }
printf "%s %s\n" "\${_STEP_NUMBERS[0]}" "\$(fake_run)"
EOF
  _result="$(bash "$_step_runner_fake_tmp/05-fake.sh" 2>/dev/null)"
  _num="${_result% *}"
  _out="${_result#* }"
  if [ "$_num" -eq 5 ] && [ "$_out" -eq 5 ]; then
    assert_pass "register_step derives step number from NN- filename prefix"
  else
    assert_fail "register_step 3-arg derive" "Expected number 5 and output 5, got: number=$_num output=$_out"
  fi
  rm -rf "$_step_runner_fake_tmp"
  trap - EXIT
}

test_register_step_no_prefix_errors() {
  local _exit_code=0 _result
  _step_runner_plain_tmp="$(mktemp -d)"
  trap 'rm -rf "$_step_runner_plain_tmp"' EXIT
  cat >"$_step_runner_plain_tmp/plain.sh" <<EOF
. "$REPO_ROOT/src/scripts/lib/step-runner.sh"
register_step "fake" "Fake" fake_run 2>/dev/null
_status=\$?
printf "count=%s\n" "\${#_STEP_FUNCS[@]}"
exit "\$_status"
EOF
  _result="$(bash "$_step_runner_plain_tmp/plain.sh" 2>/dev/null)" || _exit_code=$?
  if [ "$_exit_code" -ne 0 ] && echo "$_result" | grep -q 'count=0'; then
    assert_pass "register_step without NN- prefix errors and does not register"
  else
    assert_fail "register_step no-prefix" "Expected non-zero exit and count=0, got: exit=$_exit_code result=$_result"
  fi
  rm -rf "$_step_runner_plain_tmp"
  trap - EXIT
}

# ---- Spec B: --skip-steps flag ----

test_skip_steps_equals_form() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    parse_args "--skip-steps=a,b"
    echo "${SKIP_STEPS[*]}"
  )
  if echo "$result" | grep -q "a b"; then
    assert_pass "--skip-steps=a,b populates SKIP_STEPS with two entries"
  else
    assert_fail "--skip-steps equals" "Expected 'a b', got: $result"
  fi
}

test_skip_steps_empty_value() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    parse_args "--skip-steps="
    echo "${#SKIP_STEPS[@]}"
  )
  if [ "$result" = "0" ]; then
    assert_pass "--skip-steps= results in empty SKIP_STEPS"
  else
    assert_fail "--skip-steps empty" "Expected 0 entries, got: $result"
  fi
}

test_skip_steps_unknown_id_no_error() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args "--skip-steps=nonexistent-id"
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    assert_pass "--skip-steps with unknown ID does not error (Spec B)"
  else
    assert_fail "--skip-steps unknown" "Expected exit 0 for unknown ID, got: $exit_code"
  fi
}

test_skip_steps_dedup() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    parse_args "--skip-steps=a,a"
    echo "${SKIP_STEPS[*]} ${#SKIP_STEPS[@]}"
  )
  if echo "$result" | grep -q "a 1"; then
    assert_pass "--skip-steps=a,a deduplicates to one entry"
  else
    assert_fail "--skip-steps dedup" "Expected 'a 1', got: $result"
  fi
}

test_skip_steps_last_value_wins() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    parse_args "--skip-steps=a" "--skip-steps=b"
    echo "${SKIP_STEPS[*]}"
  )
  if echo "$result" | grep -q "b" && ! echo "$result" | grep -q "a"; then
    assert_pass "--skip-steps last value wins (no accumulation)"
  else
    assert_fail "--skip-steps last-win" "Expected 'b' only, got: $result"
  fi
}

# ---- Legacy behavior that must be preserved ----
# Some existing tests from pre-Phase-1, adapted for new signature where needed.

test_parse_args_help() {
  local exit_code
  exit_code=0

  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        usage() { echo "usage: test"; }
        parse_args --help
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 1 ]; then
    assert_fail "parse_args --help" "Unexpected exit code: $exit_code"
  else
    assert_pass "parse_args --help exits cleanly"
  fi
}

test_parse_args_scoped() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    parse_args --scoped
    echo "$SCOPED $HAS_ARGS"
  )
  if [ "$result" = "true true" ]; then
    assert_pass "parse_args --scoped sets SCOPED=true and HAS_ARGS=true"
  else
    assert_fail "parse_args --scoped" "Expected 'true true', got: $result"
  fi
}

test_parse_args_positions() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    parse_args --fail-fast path/to/file.nix
    echo "$HAS_ARGS ${POSITIONAL_ARGS[*]}"
  )
  if echo "$result" | grep -q "true.*path/to/file.nix"; then
    assert_pass "parse_args captures positional args"
  else
    assert_fail "parse_args positions" "Expected 'true ...file.nix', got: $result"
  fi
}

test_aggregate_results_parses_exit_files() {
  local result
  result=$(

    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    say() { echo "say: $*"; }
    error() { echo "error: $*" >&2; }
    _wave_init
    register_step "test" 1 "Test" test_func
    printf '%s' "0" >"$_wave_tmpdir/step-1.exit"
    printf '%s' "42" >"$_wave_tmpdir/step-1.time"
    printf '%s' "Test" >"$_wave_tmpdir/step-1.name"
    printf '%s' "100" >"$_wave_tmpdir/pipeline.wall_ms"
    # shellcheck disable=SC2317 # reason: aggregate_results calls exit, captured in subshell
    aggregate_results 2>&1 || true
  ) 2>&1
  if echo "$result" | grep -q "say: all checks passed." &&
    echo "$result" | grep -q "wall clock:" &&
    echo "$result" | grep -qE '[0-9]+\.[0-9]{3} s'; then
    assert_pass "aggregate_results parses exit files correctly"
  else
    assert_fail "aggregate_results" "Expected 'all checks passed', wall clock line, and decimal-second durations. Got: $result"
  fi
}

test_format_duration_s() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    _format_duration_s 4127
  )
  if [ "$result" = "4.127 s" ]; then
    assert_pass "_format_duration_s formats milliseconds as decimal seconds"
  else
    assert_fail "_format_duration_s" "Expected '4.127 s', got: $result"
  fi
}

test_step_now_ms_sub_second_precision() {
  local elapsed
  elapsed=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    _start=$(_step_now_ms)
    sleep 0.05
    _end=$(_step_now_ms)
    echo $((_end - _start))
  )
  if [ "$elapsed" -ge 40 ] && [ "$elapsed" -lt 1000 ]; then
    assert_pass "_step_now_ms measures sub-second intervals"
  else
    assert_fail "_step_now_ms precision" "Expected elapsed in [40, 1000) ms, got: ${elapsed}ms"
  fi
}

test_run_all_steps_parallel_jobs_cap() {
  local _log _log_contents _run_exit=0
  _log=$(mktemp)
  (
    # shellcheck disable=SC2030 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner
    export PARALLEL_JOBS=1
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    # shellcheck disable=SC2329 # reason: invoked indirectly via register_step function name
    step_one() {
      echo s1-start >>"$_log"
      sleep 0.1
      echo s1-end >>"$_log"
      return 0
    }
    # shellcheck disable=SC2329 # reason: invoked indirectly via register_step function name
    step_two() {
      echo s2-start >>"$_log"
      sleep 0.1
      echo s2-end >>"$_log"
      return 0
    }
    register_step "one" 1 "One" step_one
    register_step "two" 2 "Two" step_two
    run_all_steps
  ) >/dev/null 2>&1 || _run_exit=$?
  _log_contents=$(tr -d '\n' <"$_log")
  rm -f "$_log"
  if [ "$_run_exit" -eq 0 ] && [ "$_log_contents" = "s1-starts1-ends2-starts2-end" ]; then
    assert_pass "run_all_steps honors PARALLEL_JOBS=1 (sequential waves)"
  else
    assert_fail "parallel-jobs-cap" "Expected sequential log and exit 0, got log='$_log_contents' exit=$_run_exit"
  fi
}

# ---- Nix lock helper (Phase 9) ----
# nucleus_nix_locked serializes nix invocations across concurrent steps via a
# mkdir-based mutex (flock is unavailable on macOS).

test_nix_lock_runs_command_and_returns_exit() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    error() { echo "error: $*" >&2; }
    rm -rf "$NUCLEUS_NIX_LOCK"
    nucleus_nix_locked echo "locked-run"
    nucleus_nix_locked false
    echo "exit=$?"
    rm -rf "$NUCLEUS_NIX_LOCK"
  )
  if echo "$result" | grep -q "locked-run" && echo "$result" | grep -q "exit=1"; then
    assert_pass "nucleus_nix_locked runs the command and returns its exit code"
  else
    assert_fail "nix-lock-run" "Expected 'locked-run' and 'exit=1', got: $result"
  fi
}

test_nix_lock_recovers_stale() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    error() { echo "error: $*" >&2; }
    rm -rf "$NUCLEUS_NIX_LOCK"
    mkdir "$NUCLEUS_NIX_LOCK"
    printf '%s\n' "999999" >"$NUCLEUS_NIX_LOCK/pid" # dead PID
    nucleus_nix_locked echo "stale-recovered"
    rm -rf "$NUCLEUS_NIX_LOCK"
  )
  if echo "$result" | grep -q "stale-recovered"; then
    assert_pass "nucleus_nix_locked reclaims a stale lock from a dead owner"
  else
    assert_fail "nix-lock-stale" "Expected 'stale-recovered', got: $result"
  fi
}

test_nix_lock_serializes() {
  # Two concurrent acquisitions must not overlap: the second starts only
  # after the first releases. Use a counter file: holder increments and
  # signals ready, second must see the held count and wait.
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    error() { echo "error: $*" >&2; }
    rm -rf "$NUCLEUS_NIX_LOCK"
    local _counter _ready_file
    _counter=$(mktemp) || exit 1
    _ready_file=$(mktemp) || exit 1
    (
      # shellcheck disable=SC2016 # reason: $1/$2 are sh -c positional params, not shell expansion
      nucleus_nix_locked sh -c 'echo 1 >> "$1"; echo ready > "$2"; sleep 0.1; echo 2 >> "$1"' _ "$_counter" "$_ready_file"
    ) &
    local _holder=$!
    while [ ! -s "$_ready_file" ]; do
      sleep 0.01
    done
    # shellcheck disable=SC2016 # reason: $1 is sh -c positional param, not shell expansion
    nucleus_nix_locked sh -c 'echo 3 >> "$1"' _ "$_counter"
    wait "$_holder"
    rm -rf "$NUCLEUS_NIX_LOCK"
    cat "$_counter"
    rm -f "$_counter" "$_ready_file"
  )
  # Holder writes 1, sleeps, writes 2; second must wait for release, so
  # order is strictly 1 2 3 (never 1 3 2).
  if printf '%s\n' "$result" | grep -qx '1\|2\|3' && [ "$(printf '%s\n' "$result" | tr -d ' \n')" = "123" ]; then
    assert_pass "nucleus_nix_locked serializes concurrent nix invocations"
  else
    assert_fail "nix-lock-serial" "Expected order 123, got: $result"
  fi
}

# ---- Run tests ----
section 1 "Phase 1: Framework core unit tests (POSIX)"
echo "Tests for Spec A (step IDs) and Spec B (--skip-steps)."
echo ""

test_register_step_with_id
test_register_step_multiple_with_ids
test_register_step_id_with_digits_errors
test_register_step_empty_id_errors
test_register_step_duplicate_id_errors
test_register_step_duplicate_number_errors

echo "--- Step number derivation (3-arg form) ---"
test_register_step_derives_number_from_filename
test_register_step_no_prefix_errors

test_skip_steps_equals_form
test_skip_steps_empty_value
test_skip_steps_unknown_id_no_error
test_skip_steps_dedup
test_skip_steps_last_value_wins

echo "--- Legacy behavior tests ---"
test_parse_args_help
test_parse_args_scoped
test_parse_args_positions
test_format_duration_s
test_step_now_ms_sub_second_precision
test_aggregate_results_parses_exit_files
test_run_all_steps_parallel_jobs_cap

echo "--- Nix lock tests (Phase 9) ---"
test_nix_lock_runs_command_and_returns_exit
test_nix_lock_recovers_stale
test_nix_lock_serializes

echo ""
echo "--- Phase 1 POSIX unit tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
