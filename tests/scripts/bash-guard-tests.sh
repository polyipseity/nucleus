#!/usr/bin/env bash
# Tests for the shared bash version guard library and entrypoint wiring (G1).
#
# Run with: bash tests/scripts/bash-guard-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
GUARD_LIB="$REPO_ROOT/src/scripts/lib/bash-guard.sh"

# Guard lib exists and defines the expected API.
_t_guard_lib_exists() {
  if [ -f "$GUARD_LIB" ]; then
    assert_pass "bash-guard.sh exists at src/scripts/lib/bash-guard.sh"
  else
    assert_fail "bash-guard.sh exists" "missing $GUARD_LIB"
  fi
}

# Guard lib must parse under the host's current bash.
_t_guard_parses_under_current_bash() {
  local rc=0
  bash -n "$GUARD_LIB" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_pass "bash-guard.sh parses under the current bash"
  else
    assert_fail "bash-guard.sh parses under current bash" "bash -n exit $rc"
  fi
}

# Guard lib must parse under bash 3.2 when /bin/bash is available.
_t_guard_parses_under_bash32() {
  if [ ! -x /bin/bash ]; then
    assert_fail "bash-guard.sh parses under /bin/bash (3.2)" "/bin/bash not available"
    return
  fi
  local rc=0 out=""
  out="$(/bin/bash -n "$GUARD_LIB" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_pass "bash-guard.sh parses under /bin/bash (3.2)"
  else
    assert_fail "bash-guard.sh parses under /bin/bash (3.2)" "bash -n exit $rc: $out"
  fi
}

# A requirement above the running bash must fail, name the required version, the
# actual bash, and a copy-pastable remediation.
_t_require_fails_with_message() {
  local out="" rc=0
  out="$(bash -c '. "$1"; bash_guard_require 99 0 check' _ "$GUARD_LIB" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_fail "bash_guard_require fails when requirement is unmet" "expected non-zero exit"
    return
  fi
  local ok=1
  case "$out" in
  *99.0*) ;;
  *) ok=0 ;;
  esac
  case "$out" in
  *"${BASH_VERSION:-}"*) ;;
  *BASH* | *bash*) ;;
  *) ok=0 ;;
  esac
  case "$out" in
  *"nix run ./src#check"* | *"/run/current-system/sw/bin/bash"* | *"nucleus-check"*) ;;
  *) ok=0 ;;
  esac
  if [ "$ok" -eq 1 ]; then
    assert_pass "bash_guard_require reports required version, actual bash, and remediation"
  else
    assert_fail "bash_guard_require failure message" "rc=$rc output=[$out]"
  fi
}

# A requirement at or below the running bash must pass.
_t_require_passes_when_met() {
  local rc=0
  bash -c '. "$1"; bash_guard_require 3 2 check' _ "$GUARD_LIB" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_pass "bash_guard_require passes when the requirement is met"
  else
    assert_fail "bash_guard_require passes when requirement is met" "exit $rc"
  fi
}

# Running scripts/check.sh under bash 3.2 must print remediation and exit 1,
# never a syntax error or partial run.
_t_check_sh_guarded_under_bash32() {
  if [ ! -x /bin/bash ]; then
    assert_fail "scripts/check.sh guarded under /bin/bash (3.2)" "/bin/bash not available"
    return
  fi
  local out="" rc=0
  out="$(cd "$REPO_ROOT" && /bin/bash scripts/check.sh 2>&1)" || rc=$?
  local syntax=0
  case "$out" in
  *"syntax error"* | *"unexpected"* | *"Syntax error"*) syntax=1 ;;
  esac
  if [ "$rc" -eq 1 ] && [ "$syntax" -eq 0 ] && printf '%s\n' "$out" | grep -q '5\.1'; then
    assert_pass "scripts/check.sh exits 1 under bash 3.2 with remediation and no syntax error"
  else
    assert_fail "scripts/check.sh under bash 3.2" "rc=$rc syntax=$syntax output=[$out]"
  fi
}

# scripts/bootstrap.sh must keep its --help/usage path working under /bin/bash.
_t_bootstrap_help_under_bash32() {
  if [ ! -x /bin/bash ]; then
    assert_fail "scripts/bootstrap.sh --help works under /bin/bash (3.2)" "/bin/bash not available"
    return
  fi
  local out="" rc=0
  out="$(cd "$REPO_ROOT" && /bin/bash scripts/bootstrap.sh --help 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qi 'usage'; then
    assert_pass "scripts/bootstrap.sh --help works under /bin/bash (3.2)"
  else
    assert_fail "scripts/bootstrap.sh --help under bash 3.2" "rc=$rc output=[$out]"
  fi
}

# bootstrap.sh's reachable path must not use bash 4+/5+ constructs.
_t_bootstrap_no_modern_bash_constructs() {
  local bad=0
  # Associative arrays, namerefs, |&, declare -g, mapfile/readarray, coproc, {a..b} brace expansion with vars is hard to grep perfectly,
  # but check for clear 4+ tokens.
  if grep -nE 'declare -A|declare -g|mapfile|readarray|coproc|\|&' "$REPO_ROOT/scripts/bootstrap.sh" >/dev/null 2>&1; then
    bad=1
  fi
  if [ "$bad" -eq 0 ]; then
    assert_pass "scripts/bootstrap.sh avoids obvious bash 4+/5+ constructs"
  else
    assert_fail "scripts/bootstrap.sh 3.2-safe" "found 4+/5+ construct tokens"
  fi
}

# Modified entrypoints must not keep a duplicated inline bash version guard.
_t_no_duplicated_inline_guards() {
  local dup=0
  local f
  for f in \
    "$REPO_ROOT/scripts/check.sh" \
    "$REPO_ROOT/scripts/test.sh" \
    "$REPO_ROOT/scripts/update.sh"; do
    # Old D5 inline pattern used BASH_VERSINFO checks directly in the script.
    if grep -n 'D5: fail early with copy-pastable remediation for incompatible bash runtimes' "$f" >/dev/null 2>&1; then
      dup=1
    fi
  done
  if [ "$dup" -eq 0 ]; then
    assert_pass "check.sh, test.sh, and update.sh have no duplicated inline D5 guards"
  else
    assert_fail "no duplicated inline guards" "found legacy D5 guard marker"
  fi
}

_t_guard_lib_exists
_t_guard_parses_under_current_bash
_t_guard_parses_under_bash32
_t_require_fails_with_message
_t_require_passes_when_met
_t_check_sh_guarded_under_bash32
_t_bootstrap_help_under_bash32
_t_bootstrap_no_modern_bash_constructs
_t_no_duplicated_inline_guards

finish_tests
