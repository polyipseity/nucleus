#!/usr/bin/env bash
# Tests: run_hermetic_eval evaluates every toplevel read-only, keeps the
# environment hermetic, and still fails loudly on an unexpected error.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_step_file="$(CDPATH='' cd -- "$SCRIPT_DIR/../../../src/scripts/checks/check-steps" && pwd -P)/03-nix-flake-eval.sh"

# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"
init_test_state
# shellcheck source=../../../src/scripts/checks/check-lib.sh
. "$(CDPATH='' cd -- "$SCRIPT_DIR/../../../src/scripts/checks" && pwd -P)/check-lib.sh"

eval "$(extract_func run_hermetic_eval "$_step_file")"
eval "$(extract_func _ne_now_ms "$_step_file")"
eval "$(extract_func _ne_dur_s "$_step_file")"

_stub_dir="$(mktemp -d)"
cat >"$_stub_dir/nix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
printf 'repo_root=%s\n' "${NUCLEUS_REPO_ROOT-unset}" >>"$STUB_LOG"
printf '%s\n' "${STUB_OUT-}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$_stub_dir/nix"
export PATH="$_stub_dir:$PATH"

_hermetic_nix_files=()
declare -A _ctx=(
  [HAS_ARGS]=false
  [REPO_ROOT]="$REPO_ROOT"
  [NIX_FILES]=_hermetic_nix_files
)

_case_both_targets_read_only() {
  STUB_LOG="$(mktemp)"
  export STUB_LOG STUB_RC=0 STUB_OUT="/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system.drv"
  local _out _rc
  _out="$(run_hermetic_eval _ctx 2>&1)"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    assert_fail "both targets evaluate" "expected rc 0, got $_rc: $_out"
    return
  fi
  assert_pass "both targets evaluate"

  if [ "$(grep -c '^eval ' "$STUB_LOG")" -eq 2 ]; then
    assert_pass "two invocations recorded"
  else
    assert_fail "two invocations recorded" "log: $(cat "$STUB_LOG")"
  fi

  if grep -q -- '--read-only ./src#darwinConfigurations.MacBook.config.system.build.toplevel.drvPath' "$STUB_LOG" &&
    grep -q -- '--read-only ./src#nixosConfigurations.NixOS.config.system.build.toplevel.drvPath' "$STUB_LOG"; then
    assert_pass "each target is evaluated read-only through its drvPath"
  else
    assert_fail "each target is evaluated read-only through its drvPath" "log: $(cat "$STUB_LOG")"
  fi

  if grep -q 'eval --raw --read-only' "$STUB_LOG"; then
    assert_pass "read-only evaluation is requested"
  else
    assert_fail "read-only evaluation is requested" "log: $(cat "$STUB_LOG")"
  fi

  if [ "$(grep -c '^repo_root=unset$' "$STUB_LOG")" -eq 2 ]; then
    assert_pass "NUCLEUS_REPO_ROOT is unset for every invocation"
  else
    assert_fail "NUCLEUS_REPO_ROOT is unset for every invocation" "log: $(cat "$STUB_LOG")"
  fi

  case "$_out" in
  *"darwin toplevel passed"*"nixos toplevel passed"*) assert_pass "both pass lines are printed" ;;
  *) assert_fail "both pass lines are printed" "output: $_out" ;;
  esac
}

_case_env_regression_is_named() {
  STUB_LOG="$(mktemp)"
  export STUB_LOG STUB_RC=1 STUB_OUT="error: required argument 'repoRoot' was not supplied"
  local _out _rc
  _out="$(run_hermetic_eval _ctx 2>&1)"
  _rc=$?
  if [ "$_rc" -ne 1 ]; then
    assert_fail "env regression fails the step" "expected rc 1, got $_rc"
  else
    assert_pass "env regression fails the step"
  fi
  case "$_out" in
  *"hermetic eval regressed to env-var dependency (darwin toplevel)"*) assert_pass "regression is named for the target" ;;
  *) assert_fail "regression is named for the target" "output: $_out" ;;
  esac
}

_case_unexpected_failure_is_named() {
  STUB_LOG="$(mktemp)"
  export STUB_LOG STUB_RC=1 STUB_OUT="error: infinite recursion encountered"
  local _out _rc
  _out="$(run_hermetic_eval _ctx 2>&1)"
  _rc=$?
  if [ "$_rc" -ne 1 ]; then
    assert_fail "unexpected failure fails the step" "expected rc 1, got $_rc"
  else
    assert_pass "unexpected failure fails the step"
  fi
  case "$_out" in
  *"hermetic eval failed for an unexpected reason (nixos toplevel)"*) assert_pass "unexpected failure is named for the target" ;;
  *) assert_fail "unexpected failure is named for the target" "output: $_out" ;;
  esac
}

section "1" "hermetic eval"
_case_both_targets_read_only
_case_env_regression_is_named
_case_unexpected_failure_is_named

finish_tests
