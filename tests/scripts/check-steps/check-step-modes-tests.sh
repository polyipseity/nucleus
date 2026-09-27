#!/usr/bin/env bash
# shellcheck shell=bash
# Test: every check step declares a mode at registration, and the declared mode
# matches what the step actually does with its file arguments.
#
# The Check modes table in tooling-and-validation.instructions.md was deleted
# because it drifted: it named steps 4, 6, 9 and 14, none of which exist. Its
# replacement is the register_step call, so these tests hold the call to the
# step's behaviour. A mode nobody checks is a table that will drift again.
#
#   full  -> the step ignores its file arguments and is whole-repo only
#   any   -> the step consumes its file arguments and filters
#   scoped-> the step runs only in a scoped run
#
# A check step must stay runnable in a whole-repo run, so no check step may
# declare `scoped`: _step_mode_applicable skips a scoped step whenever
# HAS_ARGS is false, which would silence it in exactly the run CI performs.
#
# The full/any checks are inverses, so declaring the wrong mode on any step
# trips one of them rather than passing unnoticed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CHECK_STEPS_DIR="$REPO_ROOT/src/scripts/checks/check-steps"

failures=0

assert_pass() { printf 'PASS: %s\n' "$1"; }
assert_fail() {
  printf 'FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

# declared_mode <step-stem> -- the MODE token the POSIX step registers, or empty
# when it registers none. The registration is
#   register_step <id> <name> <func> <platform> <mode> <requires>
# so the mode is the second of the three trailing bare tokens. Capturing the
# first would yield the platform, and every comparison against it would match
# nothing and pass vacuously.
declared_mode() {
  sed -n 's/^register_step "[^"]*" "[^"]*" [A-Za-z0-9_]* [a-z]* \([a-z]*\) [a-z-]*$/\1/p' \
    "$CHECK_STEPS_DIR/$1.sh" | head -1
}

# consumes_file_args <step-stem> -- true when the step reads its file arguments
# anywhere beyond the `local _files=...` declaration. A whole-repo step collects
# them and never looks at them, which is what makes `full` the honest mode.
consumes_file_args() {
  local _refs
  _refs=$(grep -c '_files' "$CHECK_STEPS_DIR/$1.sh" 2>/dev/null || true)
  [ "${_refs:-0}" -gt 1 ]
}

# registers_full_form <step-stem> -- true when the call carries all three
# declared tokens as valid values. Counted by validating the trailing tokens
# rather than by counting words, because the id and the name are quoted and the
# name contains spaces, so a word count is meaningless here.
registers_full_form() {
  grep -qE \
    '^register_step "[^"]*" "[^"]*" [A-Za-z0-9_]+ (any|posix|windows) (any|full|scoped) (none|nix|network|sops-machine-key|deployed-host)$' \
    "$CHECK_STEPS_DIR/$1.sh"
}

# filterable_steps -- the steps whose declared mode is `any`. Guards against the
# comparisons below running over an empty set, which is how a broken extractor
# turns a test into a green line that checked nothing.
filterable_steps() {
  for _f in "$CHECK_STEPS_DIR"/*.sh; do
    _stem=$(basename -- "$_f" .sh)
    [ "$(declared_mode "$_stem")" = "any" ] && printf '%s\n' "$_stem"
  done
}

# whole_repo_steps -- the steps whose declared mode is `full`.
whole_repo_steps() {
  for _f in "$CHECK_STEPS_DIR"/*.sh; do
    _stem=$(basename -- "$_f" .sh)
    [ "$(declared_mode "$_stem")" = "full" ] && printf '%s\n' "$_stem"
  done
}

step_stems() {
  for _f in "$CHECK_STEPS_DIR"/*.sh; do basename -- "$_f" .sh; done | sort
}

test_every_step_declares_a_mode() {
  local _missing="" _stem
  while read -r _stem; do
    [ -n "$_stem" ] || continue
    if [ -z "$(declared_mode "$_stem")" ]; then
      _missing="${_missing} ${_stem}"
    fi
  done <<EOF
$(step_stems)
EOF
  if [ -z "$_missing" ]; then
    assert_pass "every check step declares a mode at registration"
  else
    assert_fail "these steps register without a mode:${_missing}"
  fi
}

test_no_check_step_is_scoped_only() {
  local _scoped="" _stem
  while read -r _stem; do
    [ -n "$_stem" ] || continue
    [ "$(declared_mode "$_stem")" = "scoped" ] && _scoped="${_scoped} ${_stem}"
  done <<EOF
$(step_stems)
EOF
  if [ -z "$_scoped" ]; then
    assert_pass "no check step is scoped-only (it would be skipped in a whole-repo run)"
  else
    assert_fail "these steps declare scoped and would never run whole-repo:${_scoped}"
  fi
}

test_full_steps_ignore_their_file_args() {
  local _bad="" _stem
  while read -r _stem; do
    [ -n "$_stem" ] || continue
    [ "$(declared_mode "$_stem")" = "full" ] || continue
    # A full step must not read its arguments; if it does, `any` is the honest mode.
    if consumes_file_args "$_stem"; then
      _bad="${_bad} ${_stem}"
    fi
  done <<EOF
$(step_stems)
EOF
  if [ -z "$_bad" ]; then
    assert_pass "steps declared full do not read their file arguments"
  else
    assert_fail "these steps declare full but read their file arguments, so they are filterable:${_bad}"
  fi
}

test_any_steps_consume_their_file_args() {
  local _bad="" _stem
  while read -r _stem; do
    [ -n "$_stem" ] || continue
    [ "$(declared_mode "$_stem")" = "any" ] || continue
    if ! consumes_file_args "$_stem"; then
      _bad="${_bad} ${_stem}"
    fi
  done <<EOF
$(step_stems)
EOF
  if [ -z "$_bad" ]; then
    assert_pass "steps declared any actually filter on their file arguments"
  else
    assert_fail "these steps declare any but discard their file arguments, so full is the honest mode:${_bad}"
  fi
}

test_posix_and_powershell_twins_agree() {
  local _bad="" _compared=0 _stem _ps1
  while read -r _stem; do
    [ -n "$_stem" ] || continue
    _ps1="$CHECK_STEPS_DIR/$_stem.ps1"
    [ -f "$_ps1" ] || continue
    local _sh_mode _ps_mode
    _sh_mode=$(declared_mode "$_stem")
    _ps_mode=$(sed -n 's/.*-Mode \([a-z]*\).*/\1/p' "$_ps1" | head -1)
    _compared=$((_compared + 1))
    [ "$_sh_mode" = "$_ps_mode" ] || _bad="${_bad} ${_stem}(${_sh_mode}/${_ps_mode})"
  done <<EOF
$(step_stems)
EOF
  # WHY: a lookup that silently matched no twin would leave _compared at 0 and
  # pass having compared nothing, which is the vacuity the POSIX lane guards.
  if [ "$_compared" -eq 0 ]; then
    assert_fail "every PowerShell twin declares the same mode as its POSIX step" \
      "no PowerShell twin was found under $CHECK_STEPS_DIR; compared 0 steps"
    return
  fi
  if [ -z "$_bad" ]; then
    assert_pass "every PowerShell twin declares the same mode as its POSIX step (${_compared} compared)"
  else
    assert_fail "POSIX/PowerShell mode disagreement (posix/windows):${_bad}"
  fi
}

test_full_steps_ignore_args_on_windows_too() {
  # The same honesty rule applies to the twin. A step is one answer, not two.
  local _bad="" _checked=0 _stem _ps1
  while read -r _stem; do
    [ -n "$_stem" ] || continue
    _ps1="$CHECK_STEPS_DIR/$_stem.ps1"
    [ -f "$_ps1" ] || continue
    [ "$(declared_mode "$_stem")" = "full" ] || continue
    _checked=$((_checked + 1))
    # A Windows twin that reaches for its arguments is filterable there too.
    if grep -qE 'Context\.(PositionalArgs|HasArgs)' "$_ps1"; then
      _bad="${_bad} ${_stem}"
    fi
  done <<EOF
$(step_stems)
EOF
  # WHY: no `full` step with a twin would leave _checked at 0 and pass having
  # examined nothing, which is the vacuity the POSIX lane guards.
  if [ "$_checked" -eq 0 ]; then
    assert_fail "steps declared full have PowerShell twins that ignore their arguments too" \
      "no step declared full with a PowerShell twin; checked 0 steps"
    return
  fi
  if [ -z "$_bad" ]; then
    assert_pass "steps declared full have PowerShell twins that ignore their arguments too (${_checked} checked)"
  else
    assert_fail "these full steps have twins that read their arguments:${_bad}"
  fi
}

test_registration_uses_the_six_argument_form() {
  local _bad="" _stem
  while read -r _stem; do
    [ -n "$_stem" ] || continue
    if ! registers_full_form "$_stem"; then
      _bad="${_bad} ${_stem}"
    fi
  done <<EOF
$(step_stems)
EOF
  if [ -z "$_bad" ]; then
    assert_pass "every check step uses the 6-argument register_step form"
  else
    assert_fail "these steps do not use the 6-argument form (id name func platform mode requires):${_bad}"
  fi
}

# A suite of comparisons over zero steps is a green line that proved nothing.
# This is the guard against an extractor that quietly returns nothing, which is
# exactly how an earlier draft of this file passed three of its assertions.
test_the_comparisons_actually_examine_steps() {
  local _any _full _total
  _any=$(filterable_steps | wc -l | tr -d ' ')
  _full=$(whole_repo_steps | wc -l | tr -d ' ')
  _total=$(step_stems | wc -l | tr -d ' ')
  if [ "$_total" -gt 0 ] && [ $((_any + _full)) -eq "$_total" ]; then
    assert_pass "the mode extractor classified all $_total steps ($_any any, $_full full)"
  else
    assert_fail "the mode extractor missed steps: $_total total, $_any any, $_full full"
  fi
}

for fn in \
  test_the_comparisons_actually_examine_steps \
  test_every_step_declares_a_mode \
  test_no_check_step_is_scoped_only \
  test_registration_uses_the_six_argument_form \
  test_full_steps_ignore_their_file_args \
  test_any_steps_consume_their_file_args \
  test_posix_and_powershell_twins_agree \
  test_full_steps_ignore_args_on_windows_too; do
  "$fn"
done

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s check step mode test(s) failed\n' "$failures"
  exit 1
fi
echo "PASS: check step modes"
