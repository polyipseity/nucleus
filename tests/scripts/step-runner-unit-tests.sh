#!/usr/bin/env bash
# Unit tests for step-runner.sh functions in isolation.
# Covers registration arity and token validation, the applicability matrix, and
# --only-steps.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
STEP_RUNNER="$REPO_ROOT/src/scripts/lib/step-runner.sh"
readonly REPO_ROOT STEP_RUNNER

# ---- Spec A: Step ID registration (4-arg numeric form) ----

test_register_step_with_number() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    register_step "code-formatting" 1 "Code formatting" test_func
    echo "${_STEP_IDS[0]} ${_STEP_NUMBERS[0]} ${_STEP_NAMES[0]} ${_STEP_PLATFORMS[0]} ${_STEP_MODES[0]} ${_STEP_REQUIRES[0]}"
  )
  if echo "$result" | grep -q "code-formatting 1 Code formatting any any none"; then
    assert_pass "register_step stores id, number, name and undeclared any/any/none defaults"
  else
    assert_fail "register_step 4-arg" "Expected 'code-formatting 1 Code formatting any any none', got: $result"
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

test_register_step_declared_tokens() {
  local _result _tmp
  _tmp="$(mktemp -d)"
  trap 'rm -rf "$_tmp"' EXIT
  # WHY: the 6-arg declared form derives its number from the caller file's NN-
  # prefix, so it must be exercised from a fake NN- file (not the test's own file).
  cat >"$_tmp/05-fake.sh" <<EOF
. "$REPO_ROOT/src/scripts/lib/step-runner.sh"
register_step "fake" "Fake" fake_run posix full deployed-host
printf '%s %s %s %s %s\\n' "\${_STEP_NUMBERS[0]}" "\${_STEP_PLATFORMS[0]}" "\${_STEP_MODES[0]}" "\${_STEP_REQUIRES[0]}" "\${_STEP_IDS[0]}"
EOF
  _result="$(bash "$_tmp/05-fake.sh" 2>/dev/null)"
  rm -rf "$_tmp"
  trap - EXIT
  if [ "$_result" = "05 posix full deployed-host fake" ]; then
    assert_pass "register_step stores the declared platform, mode and requires tokens (6-arg)"
  else
    assert_fail "register_step declared tokens" "Expected '05 posix full deployed-host fake', got: '$_result'"
  fi
}

test_register_step_undeclared_defaults() {
  local _result _tmp
  _tmp="$(mktemp -d)"
  trap 'rm -rf "$_tmp"' EXIT
  cat >"$_tmp/06-fake.sh" <<EOF
. "$REPO_ROOT/src/scripts/lib/step-runner.sh"
register_step "plain" "Plain" plain_run
printf '%s %s %s %s\\n' "\${_STEP_NUMBERS[0]}" "\${_STEP_PLATFORMS[0]}" "\${_STEP_MODES[0]}" "\${_STEP_REQUIRES[0]}"
EOF
  _result="$(bash "$_tmp/06-fake.sh" 2>/dev/null)"
  rm -rf "$_tmp"
  trap - EXIT
  if [ "$_result" = "06 any any none" ]; then
    assert_pass "register_step 3-arg form defaults to any/any/none and derives the number"
  else
    assert_fail "register_step 3-arg defaults" "Expected '06 any any none', got: '$_result'"
  fi
}

# assert_register_step_rejects <expected-substring> <args...>
assert_register_step_rejects() {
  local _expected="$1"
  shift
  local _label="$1"
  shift
  local _exit=0 _out
  _out=$(bash -c '. "$1"; shift; register_step "$@"' _ "$STEP_RUNNER" "$@" 2>&1) || _exit=$?
  if [ "$_exit" -ne 0 ] && [[ "$_out" == *"$_expected"* ]]; then
    assert_pass "$_label"
  else
    assert_fail "$_label" "exit=$_exit output=[$_out]"
  fi
}

test_register_step_unknown_platform_token() {
  assert_register_step_rejects "unknown platform token 'darwin' (expected posix|windows|any)" \
    "register_step rejects an unknown platform token" \
    "bad" "Bad" run_bad darwin any none
}

test_register_step_unknown_mode_token() {
  assert_register_step_rejects "unknown mode token 'partial' (expected any|full|scoped)" \
    "register_step rejects an unknown mode token" \
    "bad" "Bad" run_bad any partial none
}

test_register_step_unknown_requires_token() {
  assert_register_step_rejects "unknown requires token 'gpu' (expected none|nix|network|sops-machine-key|deployed-host)" \
    "register_step rejects an unknown requires token" \
    "bad" "Bad" run_bad any any gpu
}

test_register_step_wrong_arity_errors() {
  local _exit=0
  bash -c '. "$1"; shift; register_step "$@"' _ "$STEP_RUNNER" a b c d e 2>/dev/null || _exit=$?
  if [ "$_exit" -ne 0 ]; then
    assert_pass "register_step rejects an unsupported arity (5 args)"
  else
    assert_fail "register_step arity" "Expected non-zero exit for 5 args, got: $_exit"
  fi
}

test_register_step_id_with_digits_errors() {
  local _exit=0
  bash -c '. "$1"; shift; register_step "$@"' _ "$STEP_RUNNER" "test-1-bad" 1 "Bad" true 2>/dev/null || _exit=$?
  if [ "$_exit" -ne 0 ]; then
    assert_pass "register_step with digit in ID errors (Spec A)"
  else
    assert_fail "register_step digit ID" "Expected non-zero exit for ID containing digit, got: $_exit"
  fi
}

test_register_step_empty_id_errors() {
  local _exit=0
  bash -c '. "$1"; shift; register_step "$@"' _ "$STEP_RUNNER" "" 1 "Empty" true 2>/dev/null || _exit=$?
  if [ "$_exit" -ne 0 ]; then
    assert_pass "register_step with empty ID errors (Spec A)"
  else
    assert_fail "register_step empty ID" "Expected non-zero exit for empty ID, got: $_exit"
  fi
}

test_register_step_non_numeric_number_errors() {
  local _exit=0
  bash -c '. "$1"; shift; register_step "$@"' _ "$STEP_RUNNER" "x" "not-a-number" "Name" true 2>/dev/null || _exit=$?
  if [ "$_exit" -ne 0 ]; then
    assert_pass "register_step 4-arg form requires a numeric number"
  else
    assert_fail "register_step numeric number" "Expected non-zero exit for non-numeric \$2, got: $_exit"
  fi
}

test_register_step_duplicate_id_errors() {
  local _exit=0
  bash -c '
    . "$1"
    register_step "dup" 1 "First" true
    register_step "dup" 2 "Second" true 2>/dev/null
  ' _ "$STEP_RUNNER" 2>/dev/null || _exit=$?
  if [ "$_exit" -ne 0 ]; then
    assert_pass "register_step duplicate ID errors (Spec A)"
  else
    assert_fail "register_step dup ID" "Expected non-zero exit for duplicate ID, got: $_exit"
  fi
}

test_register_step_duplicate_number_errors() {
  local _exit=0
  bash -c '
    . "$1"
    register_step "first" 1 "First" true
    register_step "second" 1 "Second" true 2>/dev/null
  ' _ "$STEP_RUNNER" 2>/dev/null || _exit=$?
  if [ "$_exit" -ne 0 ]; then
    assert_pass "register_step duplicate number errors (Spec A)"
  else
    assert_fail "register_step dup num" "Expected non-zero exit for duplicate number, got: $_exit"
  fi
}

# ---- Step number derivation (3-arg form) ----

test_register_step_derives_number_from_filename() {
  local _result _expected="05 fake_run" _tmp
  _tmp="$(mktemp -d)"
  trap 'rm -rf "$_tmp"' EXIT
  cat >"$_tmp/05-fake.sh" <<EOF
. "$REPO_ROOT/src/scripts/lib/step-runner.sh"
register_step "fake" "Fake" fake_run
printf "%s %s\\n" "\${_STEP_NUMBERS[0]}" "\${_STEP_FUNCS[0]}"
EOF
  _result="$(bash "$_tmp/05-fake.sh" 2>/dev/null)"
  rm -rf "$_tmp"
  trap - EXIT
  if [ "$_result" = "$_expected" ]; then
    assert_pass "register_step derives step number from NN- filename prefix"
  else
    assert_fail "register_step 3-arg derive" "Expected '$_expected', got: '$_result'"
  fi
}

test_register_step_no_prefix_errors() {
  local _exit=0 _result _tmp
  _tmp="$(mktemp -d)"
  trap 'rm -rf "$_tmp"' EXIT
  cat >"$_tmp/plain.sh" <<EOF
. "$REPO_ROOT/src/scripts/lib/step-runner.sh"
register_step "fake" "Fake" fake_run 2>/dev/null
_status=\$?
printf "count=%s\\n" "\${#_STEP_FUNCS[@]}"
exit "\$_status"
EOF
  _result="$(bash "$_tmp/plain.sh" 2>/dev/null)" || _exit=$?
  rm -rf "$_tmp"
  trap - EXIT
  if [ "$_exit" -ne 0 ] && echo "$_result" | grep -q 'count=0'; then
    assert_pass "register_step without NN- prefix errors and does not register"
  else
    assert_fail "register_step no-prefix" "Expected non-zero exit and count=0, got: exit=$_exit result=$_result"
  fi
}

# ---- Spec B: Applicability matrix (_step_run_state) ----
# Every probe runs in an isolated subshell so HAS_ARGS/ONLINE/ONLY_STEPS are set
# deterministically and no step is ever executed.

step_state() {
  local _has_args="$1" _online="$2" _only_steps="$3"
  shift 3
  HAS_ARGS="$_has_args" ONLINE="$_online" ONLY_STEPS_CSV="$_only_steps" bash -c '
    . "$1"; shift
    HAS_ARGS="$HAS_ARGS"; ONLINE="$ONLINE"
    ONLY_STEPS=()
    if [ -n "${ONLY_STEPS_CSV:-}" ]; then
      IFS="," read -r -a ONLY_STEPS <<<"$ONLY_STEPS_CSV"
    fi
    _step_run_state "$@"
  ' _ "$STEP_RUNNER" "$@"
}

test_run_state_platform() {
  local _off _posix _any
  _off="$(step_state false false "" x windows any none)"
  _posix="$(step_state false false "" x posix any none)"
  _any="$(step_state false false "" x any any none)"
  if [ "$_off" = "not applicable (platform: windows)" ] && [ -z "$_posix" ] && [ -z "$_any" ]; then
    assert_pass "platform applicability: windows is off-host, posix and any run"
  else
    assert_fail "platform applicability" "windows='$_off' posix='$_posix' any='$_any'"
  fi
}

test_run_state_mode() {
  local _scoped _full _scoped_off _full_off
  _scoped="$(step_state true false "" x any scoped none)"
  _full="$(step_state true false "" x any full none)"
  _scoped_off="$(step_state false false "" x any scoped none)"
  _full_off="$(step_state false false "" x any full none)"
  if [ -z "$_scoped" ] && [ "$_full" = "not applicable (mode: full)" ] &&
    [ "$_scoped_off" = "not applicable (mode: scoped)" ] && [ -z "$_full_off" ]; then
    assert_pass "mode applicability tracks the scoped/full run"
  else
    assert_fail "mode applicability" "scoped='$_scoped' full='$_full' scopedOff='$_scoped_off' fullOff='$_full_off'"
  fi
}

test_run_state_requires_network() {
  local _offline _online _none
  _offline="$(step_state false false "" x any any network)"
  _online="$(step_state false true "" x any any network)"
  _none="$(step_state false false "" x any any none)"
  if [ "$_offline" = "not applicable (requires: network)" ] && [ -z "$_online" ] && [ -z "$_none" ]; then
    assert_pass "requires applicability: network needs --online, none always runs"
  else
    assert_fail "requires network" "offline='$_offline' online='$_online' none='$_none'"
  fi
}

test_run_state_requires_nix() {
  local _off _on
  _off="$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    HAS_ARGS=false ONLINE=false ONLY_STEPS=()
    PATH=/nonexistent _step_run_state x any any nix
  )"
  _on="$(step_state false false "" x any any nix)"
  if [ "$_off" = "not applicable (requires: nix)" ] && [ -z "$_on" ]; then
    assert_pass "requires applicability: nix is probed on PATH"
  else
    assert_fail "requires nix" "off='$_off' on='$_on'"
  fi
}

test_run_state_requires_sops_machine_key() {
  local _expected _state
  _state="$(step_state false false "" x any any sops-machine-key)"
  if [ -f /etc/sops/age/machine.txt ]; then
    _expected=""
  else
    _expected="not applicable (requires: sops-machine-key)"
  fi
  if [ "$_state" = "$_expected" ]; then
    assert_pass "requires applicability: sops-machine-key tracks the machine age key"
  else
    assert_fail "requires sops-machine-key" "got '$_state', expected '$_expected'"
  fi
}

test_run_state_requires_deployed_host() {
  local _home _off _on _root
  _home="$(mktemp -d)"
  _off="$(HOME="$_home" HAS_ARGS=false ONLINE=false ONLY_STEPS_CSV="" bash -c '
    . "$1"
    HAS_ARGS="$HAS_ARGS"; ONLINE="$ONLINE"; ONLY_STEPS=()
    _step_run_state x any any deployed-host
  ' _ "$STEP_RUNNER")"
  _root="$(HOME="$_home" bash -c '. "$1" >/dev/null 2>&1; derive_nucleus_user_root' _ "$STEP_RUNNER")"
  mkdir -p "$_root"
  : >"$_root/method1-symlink-manifest.txt"
  _on="$(HOME="$_home" HAS_ARGS=false ONLINE=false ONLY_STEPS_CSV="" bash -c '
    . "$1"
    HAS_ARGS="$HAS_ARGS"; ONLINE="$ONLINE"; ONLY_STEPS=()
    _step_run_state x any any deployed-host
  ' _ "$STEP_RUNNER")"
  rm -rf "$_home"
  if [ "$_off" = "not applicable (requires: deployed-host)" ] && [ -z "$_on" ]; then
    assert_pass "requires applicability: deployed-host tracks the method-1 manifest"
  else
    assert_fail "requires deployed-host" "off='$_off' on='$_on'"
  fi
}

test_run_state_not_selected() {
  local _chosen _other
  _chosen="$(step_state false false "chosen" chosen any any none)"
  _other="$(step_state false false "chosen" other any any none)"
  if [ -z "$_chosen" ] && [ "$_other" = "not-selected" ]; then
    assert_pass "--only-steps marks every unselected step not-selected"
  else
    assert_fail "not-selected state" "chosen='$_chosen' other='$_other'"
  fi
}

test_run_state_selection_precedence() {
  local _state
  _state="$(step_state false false "chosen" other windows full nix)"
  if [ "$_state" = "not-selected" ]; then
    assert_pass "selection is reported before applicability"
  else
    assert_fail "selection precedence" "Expected 'not-selected', got '$_state'"
  fi
}

# ---- Spec C: --only-steps flag (via parse_args) ----

test_only_steps_equals_form() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    register_step "alpha" 1 "Alpha" true
    register_step "beta" 2 "Beta" true
    parse_args "--only-steps=alpha,beta"
    echo "${ONLY_STEPS[*]}"
  )
  if echo "$result" | grep -q "alpha beta"; then
    assert_pass "--only-steps=alpha,beta populates ONLY_STEPS with two entries"
  else
    assert_fail "--only-steps equals" "Expected 'alpha beta', got: $result"
  fi
}

test_only_steps_empty_value() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    register_step "alpha" 1 "Alpha" true
    parse_args "--only-steps="
    echo "${#ONLY_STEPS[@]}"
  )
  if [ "$result" = "0" ]; then
    assert_pass "--only-steps= is a no-op (empty selection)"
  else
    assert_fail "--only-steps empty" "Expected 0 entries, got: $result"
  fi
}

test_only_steps_dedup() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    register_step "alpha" 1 "Alpha" true
    parse_args "--only-steps=alpha,alpha"
    echo "${ONLY_STEPS[*]} ${#ONLY_STEPS[@]}"
  )
  if echo "$result" | grep -q "alpha 1"; then
    assert_pass "--only-steps=alpha,alpha deduplicates to one entry"
  else
    assert_fail "--only-steps dedup" "Expected 'alpha 1', got: $result"
  fi
}

test_only_steps_last_value_wins() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    usage() { true; }
    register_step "alpha" 1 "Alpha" true
    register_step "beta" 2 "Beta" true
    parse_args "--only-steps=alpha" "--only-steps=beta"
    echo "${ONLY_STEPS[*]}"
  )
  if echo "$result" | grep -q "beta" && ! echo "$result" | grep -q "alpha"; then
    assert_pass "--only-steps last value wins (no accumulation)"
  else
    assert_fail "--only-steps last-win" "Expected 'beta' only, got: $result"
  fi
}

test_only_steps_unknown_id_errors() {
  local _exit=0 _out
  _out=$(bash -c '
    . "$1"
    usage() { true; }
    register_step "alpha" 1 "Alpha" true
    parse_args "--only-steps=nonexistent-id"
  ' _ "$STEP_RUNNER" 2>&1) || _exit=$?
  if [ "$_exit" -ne 0 ] && [[ "$_out" == *"unknown step id 'nonexistent-id' in --only-steps (known: alpha)"* ]]; then
    assert_pass "--only-steps with an unknown id is a hard error"
  else
    assert_fail "--only-steps unknown" "exit=$_exit output=[$_out]"
  fi
}

# ---- Dispatch: declared applicability replaces skipping ----

test_run_all_steps_reports_not_applicable_and_passes() {
  local _out _exit=0
  _out=$(
    # shellcheck disable=SC2030,SC2031 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner; the change is scoped to that subshell
    export PARALLEL_JOBS=1
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    # shellcheck disable=SC2329 # reason: invoked indirectly via register_step function name
    step_ok() { return 0; }
    # shellcheck disable=SC2329 # reason: invoked indirectly via register_step function name
    step_off() {
      echo "MUST-NOT-RUN"
      return 0
    }
    register_step "one" 1 "One" step_ok
    register_step "win" 2 "Win" step_off
    # Simulate a windows-only declaration without the 6-arg form's filename requirement.
    _STEP_PLATFORMS[1]="windows"
    run_all_steps
    aggregate_results
  ) 2>&1 || _exit=$?
  if [ "$_exit" -eq 0 ] &&
    [[ "$_out" == *"=== [2] Win === not applicable (platform: windows)"* ]] &&
    [[ "$_out" != *"MUST-NOT-RUN"* ]]; then
    assert_pass "run_all_steps reports a not-applicable step, never runs it, and still passes"
  else
    assert_fail "run_all_steps not-applicable" "exit=$_exit output=[$_out]"
  fi
}

# ---- Argument parsing and shared helpers ----

test_parse_args_help() {
  local exit_code
  exit_code=0

  bash -c '
        . "$1"
        usage() { echo "usage: test"; }
        parse_args --help
    ' _ "$STEP_RUNNER" 2>/dev/null || exit_code=$?
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
    # shellcheck disable=SC2030,SC2031 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner; the change is scoped to that subshell
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
section 1 "Framework core unit tests (POSIX)"
echo "Registration arity, token validation, applicability matrix, --only-steps."
echo ""

test_register_step_with_number
test_register_step_multiple_with_ids
test_register_step_declared_tokens
test_register_step_undeclared_defaults
test_register_step_unknown_platform_token
test_register_step_unknown_mode_token
test_register_step_unknown_requires_token
test_register_step_wrong_arity_errors
test_register_step_id_with_digits_errors
test_register_step_empty_id_errors
test_register_step_non_numeric_number_errors
test_register_step_duplicate_id_errors
test_register_step_duplicate_number_errors

echo "--- Step number derivation (3-arg form) ---"
test_register_step_derives_number_from_filename
test_register_step_no_prefix_errors

echo "--- Applicability matrix ---"
test_run_state_platform
test_run_state_mode
test_run_state_requires_network
test_run_state_requires_nix
test_run_state_requires_sops_machine_key
test_run_state_requires_deployed_host
test_run_state_not_selected
test_run_state_selection_precedence

echo "--- --only-steps flag ---"
test_only_steps_equals_form
test_only_steps_empty_value
test_only_steps_dedup
test_only_steps_last_value_wins
test_only_steps_unknown_id_errors

echo "--- Dispatch ---"
test_run_all_steps_reports_not_applicable_and_passes

echo "--- Argument parsing and shared helpers ---"
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

finish_tests
