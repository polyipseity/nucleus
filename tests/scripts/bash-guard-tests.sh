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
# actual bash, and a copy-pastable provisioned-bash remediation.
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
  *'PATH="'*'/run/current-system/sw/bin/bash '*) ;;
  *) ok=0 ;;
  esac
  if [ "$ok" -eq 1 ]; then
    assert_pass "bash_guard_require reports required version, actual bash, and provisioned-bash remediation"
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

# A temp script outside scripts/ must be named by its actual path in remediation.
_t_require_names_actual_script_outside_scripts() {
  local tmp_dir tmp_script out="" rc=0
  tmp_dir="$(mktemp -d)"
  tmp_script="$tmp_dir/outside-scripts-guarded.sh"
  cat >"$tmp_script" <<SCRIPT
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$GUARD_LIB"
bash_guard_require 9 9 custom-outside
SCRIPT
  chmod +x "$tmp_script"
  out="$(bash "$tmp_script" 2>&1)" || rc=$?
  rm -rf "$tmp_dir"
  if [ "$rc" -eq 0 ]; then
    assert_fail "bash_guard_require names the actual script outside scripts/" "expected non-zero exit"
    return
  fi
  if printf '%s\n' "$out" | grep -qF "$tmp_script" && ! printf '%s\n' "$out" | grep -q './scripts/'; then
    assert_pass "bash_guard_require remediation names the actual script path outside scripts/"
  else
    assert_fail "bash_guard_require remediation names actual script path" "rc=$rc output=[$out]"
  fi
}

# Running scripts/check.sh under /bin/bash must behave correctly for that
# /bin/bash version: below 5.1 it must print remediation and exit 1 with no
# syntax error; at or above 5.1 it must list steps successfully via
# --list-steps (handled before preflight) with no guard-remediation text.
_t_check_sh_under_bin_bash() {
  if [ ! -x /bin/bash ]; then
    assert_fail "scripts/check.sh under /bin/bash" "/bin/bash not available"
    return
  fi
  local ver_out major minor out="" rc=0
  ver_out="$(/bin/bash -c 'printf "%s %s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')"
  major="${ver_out%% *}"
  minor="${ver_out##* }"
  if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 1 ]; }; then
    out="$(cd "$REPO_ROOT" && /bin/bash scripts/check.sh 2>&1)" || rc=$?
    local syntax=0
    case "$out" in
    *"syntax error"* | *"unexpected"* | *"Syntax error"*) syntax=1 ;;
    esac
    if [ "$rc" -eq 1 ] && [ "$syntax" -eq 0 ] && printf '%s\n' "$out" | grep -q '5\.1'; then
      assert_pass "scripts/check.sh exits 1 under /bin/bash < 5.1 with remediation and no syntax error"
    else
      assert_fail "scripts/check.sh under /bin/bash < 5.1" "rc=$rc syntax=$syntax output=[$out]"
    fi
  else
    out="$(cd "$REPO_ROOT" && /bin/bash scripts/check.sh --list-steps 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ] && ! printf '%s\n' "$out" | grep -q 'requires bash >='; then
      assert_pass "scripts/check.sh --list-steps succeeds under /bin/bash >= 5.1 with no guard-remediation text"
    else
      assert_fail "scripts/check.sh --list-steps under /bin/bash >= 5.1" "rc=$rc output=[$out]"
    fi
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

# Every bash_guard_require <major> <minor> declaration in scripts/**/*.sh and
# src/scripts/**/*.sh must declare at least 5 1, except the bootstrap-path set
# (scripts/bootstrap.sh, src/scripts/packages/install-pwsh-module.sh) which must
# declare 3 2.
_t_bash_guard_floor_policy() {
  local match file lnum text rel major minor ok=1
  local violations=""
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    file="${match%%:*}"
    lnum="${match#*:}"
    lnum="${lnum%%:*}"
    text="${match#*:*:}"
    rel="${file#"$REPO_ROOT"/}"
    # Only numeric floor declarations/calls are subject to the policy.
    # Definition lines and argument-forwarding calls are not declarations.
    if [[ $text =~ bash_guard_require[[:space:]]+([0-9]+)[[:space:]]+([0-9]+) ]]; then
      major="${BASH_REMATCH[1]}"
      minor="${BASH_REMATCH[2]}"
    else
      continue
    fi
    case "$rel" in
    scripts/bootstrap.sh | src/scripts/packages/install-pwsh-module.sh)
      if [ "$major" -ne 3 ] || [ "$minor" -ne 2 ]; then
        violations="${violations}${rel}:${lnum}: bootstrap-path exception must declare 3 2 (got ${major} ${minor})"$'\n'
        ok=0
      fi
      ;;
    *)
      if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 1 ]; }; then
        violations="${violations}${rel}:${lnum}: must declare at least 5 1 (got ${major} ${minor})"$'\n'
        ok=0
      fi
      ;;
    esac
  done < <(
    find "$REPO_ROOT/scripts" "$REPO_ROOT/src/scripts" -type f -name '*.sh' -print0 |
      xargs -0 grep -nH 'bash_guard_require' 2>/dev/null |
      LC_ALL=C sort
  )
  if [ "$ok" -eq 1 ]; then
    assert_pass "bash guard floors: bootstrap-path scripts (scripts/bootstrap.sh, src/scripts/packages/install-pwsh-module.sh) declare 3 2; all others >= 5.1"
  else
    assert_fail "bash guard floor policy" "$(printf '%s' "$violations")"
  fi
}

_t_guard_lib_exists
_t_guard_parses_under_current_bash
_t_guard_parses_under_bash32
_t_require_fails_with_message
_t_require_passes_when_met
_t_require_names_actual_script_outside_scripts
_t_check_sh_under_bin_bash
_t_bootstrap_help_under_bash32
_t_bootstrap_no_modern_bash_constructs
_t_no_duplicated_inline_guards
_t_bash_guard_floor_policy

# F1 sweep: every directly invocable POSIX bash script in scripts/*.sh and
# src/scripts/**/*.sh must have a bash guard (bash_guard_require). Bootstrap is
# allowed to require 3.2; sourced libs and explicit non-bash fragments are exempt.
# shellcheck disable=SC2329 # reason: invoked at end of script
_t_guard_sweep() {
  local unguarded=0
  local f rel
  # Explicit exception list (commented): non-bash fragments that must not carry
  # a bash 5.1 guard. Sourced libs, loaders, and step definitions are exempted
  # structurally in the sweep loop below.
  local -a _exempt=(
    # non-bash fragments (POSIX sh / guest scripts), not standalone bash entrypoints
    "src/scripts/safe-delete-rm.sh"
    "src/scripts/safe-delete-shim.sh"
    "src/scripts/vms/android-fake-wifi-guest-revert.sh"
    "src/scripts/vms/android-fake-wifi-guest-setup.sh"
    "src/scripts/cleanup-nix-build-artifacts.sh"
  )
  _is_exempt() {
    local _x
    for _x in "${_exempt[@]}"; do
      [ "$1" = "$_x" ] && return 0
    done
    return 1
  }
  while IFS= read -r f; do
    rel="${f#"$REPO_ROOT"/}"
    case "$rel" in
    src/scripts/lib/* | src/scripts/checks/check-steps/* | src/scripts/tests/test-steps/* | src/scripts/checks/*-lib.sh | src/scripts/tests/test-lib.sh) continue ;;
    esac
    _is_exempt "$rel" && continue
    # bootstrap 3.2 is an allowed guard variant, not unguarded
    if ! grep -q 'bash_guard_require' "$f"; then
      printf '  unguarded: %s\n' "$rel" >&2
      unguarded=1
    fi
  done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/src/scripts" -type f -name '*.sh' | LC_ALL=C sort)
  if [ "$unguarded" -eq 0 ]; then
    assert_pass "F1 sweep: all standalone scripts in scripts/*.sh and src/scripts/**/*.sh are guarded or explicitly exempt"
  else
    assert_fail "F1 sweep: every standalone script has a bash guard or explicit exemption" "see unguarded list above"
  fi
}

_t_guard_sweep

finish_tests
