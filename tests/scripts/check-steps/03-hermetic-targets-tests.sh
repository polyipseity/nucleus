#!/usr/bin/env bash
# Tests: run_hermetic_eval evaluates every toplevel, registers evaluated paths,
# keeps the environment hermetic, and still fails loudly on an unexpected error.
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

_real_nix="$(command -v nix 2>/dev/null || true)"
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

_case_both_targets_eval_drvpath_without_read_only() {
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

  if grep -q -- '--read-only' "$STUB_LOG"; then
    assert_fail "--read-only is not used" "log: $(cat "$STUB_LOG")"
  else
    assert_pass "--read-only is not used"
  fi

  if grep -q -- 'eval --raw ./src#darwinConfigurations.MacBook.config.system.build.toplevel.drvPath' "$STUB_LOG" &&
    grep -q -- 'eval --raw ./src#nixosConfigurations.NixOS.config.system.build.toplevel.drvPath' "$STUB_LOG"; then
    assert_pass "each target is evaluated via drvPath without --read-only"
  else
    assert_fail "each target is evaluated via drvPath without --read-only" "log: $(cat "$STUB_LOG")"
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

_case_poisoned_eval_cache_is_named() {
  STUB_LOG="$(mktemp)"
  export STUB_LOG STUB_RC=1
  export STUB_OUT="error: evaluation of cached failed attribute 'darwinConfigurations.MacBook.config.system.build.toplevel' unexpectedly succeeded"
  local _out _rc
  _out="$(run_hermetic_eval _ctx 2>&1)"
  _rc=$?
  if [ "$_rc" -ne 1 ]; then
    assert_fail "the poisoned cache fails the step" "expected rc 1, got $_rc: $_out"
    return
  fi
  case "$_out" in
  *"hermetic eval hit a poisoned eval-cache record (darwin toplevel): an earlier evaluation of this attribute failed and Nix refuses to trust a later success. Clear the stale record, or fix the impure fetch that failed:"*)
    assert_pass "the poisoned cache is named as the cause"
    ;;
  *)
    assert_fail "the poisoned cache is named as the cause" "reported: $_out"
    ;;
  esac
}

_case_behavioural_real_nix_registers_paths() {
  if [ -z "${_real_nix:-}" ] || ! command -v "$_real_nix" >/dev/null 2>&1; then
    echo "SKIP: behavioural nix eval test (no real nix on PATH)"
    assert_pass "behavioural test skipped (no nix)"
    return
  fi
  if ! "$_real_nix" --version >/dev/null 2>&1; then
    echo "SKIP: behavioural nix eval test (nix not functional)"
    assert_pass "behavioural test skipped (nix not functional)"
    return
  fi
  local _tdir _sys _outpath _rc
  _tdir="$(mktemp -d)"
  _sys="$("$_real_nix" config show system 2>/dev/null || true)"
  if [ -z "$_sys" ]; then
    echo "SKIP: behavioural nix eval test (cannot determine system)"
    assert_pass "behavioural test skipped (cannot determine system)"
    rm -rf "$_tdir"
    return
  fi
  cat >"$_tdir/flake.nix" <<EOF
{
  outputs = { ... }: {
    packages.${_sys}.foo = builtins.path { path = ./.; name = "tiny-flake-src"; };
  };
}
EOF
  _outpath="$("$_real_nix" eval --raw "$_tdir#packages.${_sys}.foo" 2>&1)"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    assert_fail "behavioural: nix eval --raw succeeds" "rc=$_rc out=$_outpath"
    rm -rf "$_tdir"
    return
  fi
  assert_pass "behavioural: nix eval --raw succeeds"
  case "$_outpath" in
  /nix/store/*) assert_pass "behavioural: eval returns a /nix/store path" ;;
  *)
    assert_fail "behavioural: eval returns a /nix/store path" "got: $_outpath"
    rm -rf "$_tdir"
    return
    ;;
  esac
  if "$_real_nix" path-info "$_outpath" >/dev/null 2>&1; then
    assert_pass "behavioural: nix path-info succeeds for evaluated path"
  else
    assert_fail "behavioural: nix path-info succeeds for evaluated path" "path-info failed for $_outpath"
  fi
  rm -rf "$_tdir"
}

section "1" "hermetic eval"
_case_both_targets_eval_drvpath_without_read_only
_case_env_regression_is_named
_case_unexpected_failure_is_named
_case_poisoned_eval_cache_is_named
_case_behavioural_real_nix_registers_paths

finish_tests
