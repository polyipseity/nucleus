#!/usr/bin/env bash
# Test: the srt agent wrappers forward the wrapped command's arguments intact.
#
# `pi` is wrapped so it runs inside srt. srt is a commander program that parses
# its own options (-h, -V, -d, -s, -c, --control-fd) wherever they appear, so a
# wrapper that forwards arguments without an end-of-options marker loses them:
# `pi --help` printed srt's usage, and `pi -c 'echo hi'` dropped both arguments
# without an error. The marker belongs after the wrapped command name, and
# `pi-unrestricted` must reach the real binary instead of re-entering `pi`.
#
# Both hosts are exercised with recording stubs on PATH, so the assertions are
# about the exact argv the wrapper hands to srt, not about srt's behaviour.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command zsh "zsh loads the extracted wrapper from src/scripts/shell/init.zsh"
require_command pwsh "pwsh loads the extracted wrapper from src/scripts/shell/profile.ps1"
require_command awk "the wrapper extraction parses both shell sources"

_spw_tmp="$(mktemp -d)"
trap 'rm -rf "$_spw_tmp"' EXIT

_spw_srt_log="$_spw_tmp/srt.log"
_spw_pi_log="$_spw_tmp/pi.log"
_spw_srt_env_log="$_spw_tmp/srt.env.log"
_spw_pi_env_log="$_spw_tmp/pi.env.log"
export SRT_LOG="$_spw_srt_log"
export PI_LOG="$_spw_pi_log"

# WHY: the NODE_OPTIONS assertions below are exact, so the harness environment
# must not decide them. A case that needs a value sets it for that one call.
unset NODE_OPTIONS

# WHY the wrappers are extracted instead of sourced whole: init.zsh is an
# interactive profile (compinit, mkdir, starship), so it cannot be sourced by a
# suite. Extracting both wrappers the same way also avoids carrying the
# __NUCLEUS_*__ token list that tests/scripts/pwsh-ssh-agent-profile-tests.sh
# has to substitute before pwsh.nix's profile will load.
_spw_zsh_pi="$_spw_tmp/wrappers.zsh.pi"
_spw_zsh_unrestricted="$_spw_tmp/wrappers.zsh.pi-unrestricted"
_spw_ps1_pi="$_spw_tmp/wrappers.ps1.pi"
_spw_ps1_unrestricted="$_spw_tmp/wrappers.ps1.pi-unrestricted"
extract_func pi "$REPO_ROOT/src/scripts/shell/init.zsh" >"$_spw_zsh_pi"
extract_func pi-unrestricted "$REPO_ROOT/src/scripts/shell/init.zsh" >"$_spw_zsh_unrestricted"
# The PowerShell twin declares `function <name> {` rather than `<name>() {`, so
# test-lib's extract_func does not match it. Its first sub drops the trailing CR:
# profile.ps1 is stored with CRLF endings, and the match and the assertions both
# compare against bare text. PowerShell accepts the LF-normalized copy.
_spw_ps1_extract() { # <name>
  awk -v name="$1" '
    { sub(/\r$/, "") }
    $0 == "function " name " {" { p = 1 }
    p { print }
    p && $0 == "}" { p = 0; exit }
  ' "$REPO_ROOT/src/scripts/shell/profile.ps1"
}
_spw_ps1_extract pi >"$_spw_ps1_pi"
_spw_ps1_extract pi-unrestricted >"$_spw_ps1_unrestricted"
_spw_zsh_wrappers="$_spw_tmp/wrappers.zsh"
_spw_ps1_wrappers="$_spw_tmp/wrappers.ps1"
cat "$_spw_zsh_pi" "$_spw_zsh_unrestricted" >"$_spw_zsh_wrappers"
cat "$_spw_ps1_pi" "$_spw_ps1_unrestricted" >"$_spw_ps1_wrappers"

# An extraction that matched nothing would leave the suite asserting against an
# empty definition, which passes for any input. Pin the shape instead.
assert_extraction_complete() { # <label> <file> <first line> <last line>
  local _label="$1" _file="$2" _first="$3" _last="$4" _actual_first _actual_last
  _actual_first="$(head -n 1 "$_file")"
  _actual_last="$(tail -n 1 "$_file")"
  if [ "$_actual_first" != "$_first" ] || [ "$_actual_last" != "$_last" ]; then
    assert_fail "$_label" "extracted [$_actual_first] ... [$_actual_last], expected [$_first] ... [$_last]"
    return
  fi
  assert_pass "$_label"
}
# Recording stubs. Each writes two records per invocation, both opening with the
# stub tag: the arguments joined with US (0x1f), which cannot occur in the
# arguments under test, and the NODE_OPTIONS the wrapper ran with. The records go
# to separate logs, so an argv assertion keeps its exact expectation whatever the
# environment holds. Nothing here executes the wrapped command, so an argument
# the wrapper dropped shows up as a missing field rather than as a side effect.
_spw_write_stub() { # <path> <tag> <argv log> <env log>
  cat >"$1" <<STUB
#!/bin/sh
{
  printf '%s' '$2'
  for _spw_arg in "\$@"; do printf '\037%s' "\$_spw_arg"; done
  printf '\n'
} >>"$3"
{
  printf '%s' '$2'
  printf '\037%s' "\${NODE_OPTIONS-}"
  printf '\n'
} >>"$4"
STUB
  chmod +x "$1"
}

_spw_stub_bin="$_spw_tmp/bin"
_spw_stub_bin2="$_spw_tmp/bin2"
mkdir -p "$_spw_stub_bin" "$_spw_stub_bin2"
_spw_write_stub "$_spw_stub_bin/srt" srt "$_spw_srt_log" "$_spw_srt_env_log"
_spw_write_stub "$_spw_stub_bin/pi" pi-bin "$_spw_pi_log" "$_spw_pi_env_log"
_spw_write_stub "$_spw_stub_bin2/pi" pi-bin2 "$_spw_pi_log" "$_spw_pi_env_log"

# A failing srt proves the wrapper hands its exit status back to the caller.
_spw_fail_bin="$_spw_tmp/bin-fail"
mkdir -p "$_spw_fail_bin"
_spw_write_stub "$_spw_fail_bin/srt" srt-fail "$_spw_srt_log" "$_spw_srt_env_log"
printf 'exit 7\n' >>"$_spw_fail_bin/srt"

reset_logs() {
  : >"$_spw_srt_log"
  : >"$_spw_pi_log"
  : >"$_spw_srt_env_log"
  : >"$_spw_pi_env_log"
}

_spw_status=0
_spw_output=""

run_zsh_case() { # <path prefix> <invocation>
  local _prefix="$1" _invocation="$2" _driver="$_spw_tmp/case.zsh"
  _spw_status=0
  _spw_output="$_spw_tmp/zsh.out"
  {
    cat "$_spw_zsh_wrappers"
    printf '\n%s\n' "$_invocation"
    # The probe runs after the invocation and the driver exits with the
    # invocation's status, so neither the caller environment nor the exit
    # status is masked.
    cat <<'PROBE'
_spw_probe_status=$?
printf 'node-options-after:%s\n' "${NODE_OPTIONS-}"
(exit "$_spw_probe_status")
PROBE
  } >"$_driver"
  PATH="$_prefix:$PATH" zsh "$_driver" >"$_spw_output" 2>&1 || _spw_status=$?
}

run_pwsh_case() { # <path prefix> <invocation>
  local _prefix="$1" _invocation="$2" _driver="$_spw_tmp/case.ps1"
  _spw_status=0
  _spw_output="$_spw_tmp/pwsh.out"
  {
    cat "$_spw_ps1_wrappers"
    printf '\n%s\n' "$_invocation"
    # Same contract as the zsh driver: observe the restored environment, then
    # exit with the invocation's status.
    cat <<'PROBE'
$spwStatus = $LASTEXITCODE
Write-Output "node-options-after:$env:NODE_OPTIONS"
exit $spwStatus
PROBE
  } >"$_driver"
  PATH="$_prefix:$PATH" pwsh -NoProfile -File "$_driver" >"$_spw_output" 2>&1 || _spw_status=$?
}

assert_interpreter_ran() { # <label>
  if [ "$_spw_status" -ne 0 ]; then
    assert_fail "$1" "wrapper exited $_spw_status: $(tr '\n' ' ' <"$_spw_output")"
    return 1
  fi
  return 0
}

assert_log_equals() { # <label> <log> <tag> <expected arg...>
  local _label="$1" _log="$2" _tag="$3" _expected="$_spw_tmp/expected.txt" _diff="$_spw_tmp/diff.txt" _a
  shift 3
  {
    printf '%s' "$_tag"
    for _a in "$@"; do printf '\037%s' "$_a"; done
    printf '\n'
  } >"$_expected"
  if [ ! -e "$_log" ]; then
    assert_fail "$_label" "$_log was never created, so the stub was never invoked"
    return
  fi
  if diff -u "$_expected" "$_log" >"$_diff" 2>&1; then
    assert_pass "$_label"
  else
    assert_fail "$_label" "recorded [$(tr '\037' ' ' <"$_log" | tr '\n' ' ')], expected [$(tr '\037' ' ' <"$_expected" | tr '\n' ' ')]"
  fi
}

assert_log_empty() { # <label> <log>
  if [ -s "$2" ]; then
    assert_fail "$1" "$2 holds [$(tr '\037' ' ' <"$2" | tr '\n' ' ')]"
    return
  fi
  assert_pass "$1"
}

assert_single_record() { # <label> <log>
  local _count
  _count="$(wc -l <"$2" | tr -d '[:space:]')"
  if [ "$_count" -ne 1 ]; then
    assert_fail "$1" "$2 holds $_count records, expected 1"
    return
  fi
  assert_pass "$1"
}

assert_output_line() { # <label> <expected line>
  if grep -Fxq -- "$2" "$_spw_output"; then
    assert_pass "$1"
    return
  fi
  assert_fail "$1" "output was [$(tr '\n' ' ' <"$_spw_output")], expected line [$2]"
}

assert_exit_status() { # <label> <expected status>
  if [ "$_spw_status" -eq "$2" ]; then
    assert_pass "$1"
    return
  fi
  assert_fail "$1" "wrapper exited $_spw_status, expected $2: $(tr '\n' ' ' <"$_spw_output")"
}

assert_extraction_complete "zsh: init.zsh pi() extracted whole" \
  "$_spw_zsh_pi" "pi() {" "}"
assert_extraction_complete "zsh: init.zsh pi-unrestricted() extracted whole" \
  "$_spw_zsh_unrestricted" "pi-unrestricted() {" "}"
assert_extraction_complete "pwsh: profile.ps1 pi function extracted whole" \
  "$_spw_ps1_pi" "function pi {" "}"
assert_extraction_complete "pwsh: profile.ps1 pi-unrestricted function extracted whole" \
  "$_spw_ps1_unrestricted" "function pi-unrestricted {" "}"

section 1 "zsh wrapper (src/scripts/shell/init.zsh)"

reset_logs
run_zsh_case "$_spw_stub_bin" 'pi --help'
assert_interpreter_ran "zsh: pi --help runs" &&
  assert_log_equals "zsh: pi --help reaches srt as command pi -- --help" \
    "$_spw_srt_log" srt command pi -- --help &&
  assert_log_empty "zsh: pi --help does not invoke pi directly" "$_spw_pi_log"

reset_logs
run_zsh_case "$_spw_stub_bin" 'pi -p "x y" --mode json'
assert_interpreter_ran "zsh: multi-argument invocation runs" &&
  assert_log_equals "zsh: an argument containing a space stays one element" \
    "$_spw_srt_log" srt command pi -- -p "x y" --mode json

reset_logs
run_zsh_case "$_spw_stub_bin" 'pi'
assert_interpreter_ran "zsh: bare pi runs" &&
  assert_log_equals "zsh: bare pi forwards only the marker, never a bare --" \
    "$_spw_srt_log" srt command pi --

reset_logs
run_zsh_case "$_spw_stub_bin" 'pi -- --raw'
assert_interpreter_ran "zsh: pi with a user-supplied -- runs" &&
  assert_log_equals "zsh: a user-supplied -- reaches pi" \
    "$_spw_srt_log" srt command pi -- -- --raw

reset_logs
run_zsh_case "$_spw_stub_bin" 'pi -c "echo hi"'
assert_interpreter_ran "zsh: pi -c runs" &&
  assert_log_equals "zsh: -c is not swallowed by srt" \
    "$_spw_srt_log" srt command pi -- -c "echo hi"

reset_logs
run_zsh_case "$_spw_stub_bin" 'pi-unrestricted --version'
assert_interpreter_ran "zsh: pi-unrestricted runs" &&
  assert_log_equals "zsh: pi-unrestricted calls pi directly" \
    "$_spw_pi_log" pi-bin --version &&
  assert_log_empty "zsh: pi-unrestricted never enters srt" "$_spw_srt_log"

# srt's node gives each address family 250 ms, and an instant IPv6
# EHOSTUNREACH then cancels a healthy IPv4 dial, which the proxy reports as a
# 502. The flag has to reach srt's node without touching the caller.
reset_logs
run_zsh_case "$_spw_stub_bin" 'pi --help'
assert_interpreter_ran "zsh: pi runs with a clean NODE_OPTIONS" &&
  assert_log_equals "zsh: pi hands srt the autoselect window flag" \
    "$_spw_srt_env_log" srt --network-family-autoselection-attempt-timeout=10000 &&
  assert_log_equals "zsh: the flag leaves the forwarded argv unchanged" \
    "$_spw_srt_log" srt command pi -- --help

reset_logs
NODE_OPTIONS='--max-old-space-size=4096' run_zsh_case "$_spw_stub_bin" 'pi --help'
assert_interpreter_ran "zsh: pi runs with an inherited NODE_OPTIONS" &&
  assert_log_equals "zsh: an inherited NODE_OPTIONS is prepended to, never replaced" \
    "$_spw_srt_env_log" srt '--max-old-space-size=4096 --network-family-autoselection-attempt-timeout=10000' &&
  assert_output_line "zsh: a per-command assignment leaves the caller's value alone" \
    'node-options-after:--max-old-space-size=4096'

reset_logs
NODE_OPTIONS='--max-old-space-size=4096' run_zsh_case "$_spw_stub_bin" 'pi-unrestricted --version'
assert_interpreter_ran "zsh: pi-unrestricted runs with an inherited NODE_OPTIONS" &&
  assert_log_equals "zsh: pi-unrestricted does not gain the sandbox flag" \
    "$_spw_pi_env_log" pi-bin '--max-old-space-size=4096' &&
  assert_log_equals "zsh: pi-unrestricted still calls pi directly" \
    "$_spw_pi_log" pi-bin --version &&
  assert_log_empty "zsh: pi-unrestricted never enters srt with the flag present" "$_spw_srt_log"

reset_logs
run_zsh_case "$_spw_fail_bin" 'pi --help'
assert_exit_status "zsh: pi propagates srt's exit status" 7
unset NODE_OPTIONS

section 2 "PowerShell wrapper (src/scripts/shell/profile.ps1)"

reset_logs
run_pwsh_case "$_spw_stub_bin" 'pi --help'
assert_interpreter_ran "pwsh: pi --help runs" &&
  assert_log_equals "pwsh: pi --help reaches srt as command pi -- --help" \
    "$_spw_srt_log" srt command pi -- --help &&
  assert_log_empty "pwsh: pi --help does not invoke pi directly" "$_spw_pi_log"

reset_logs
run_pwsh_case "$_spw_stub_bin" 'pi -p "x y" --mode json'
assert_interpreter_ran "pwsh: multi-argument invocation runs" &&
  assert_log_equals "pwsh: an argument containing a space stays one element" \
    "$_spw_srt_log" srt command pi -- -p "x y" --mode json

reset_logs
run_pwsh_case "$_spw_stub_bin" 'pi'
assert_interpreter_ran "pwsh: bare pi runs" &&
  assert_log_equals "pwsh: bare pi forwards only the marker, never a bare --" \
    "$_spw_srt_log" srt command pi --

reset_logs
run_pwsh_case "$_spw_stub_bin" 'pi -- --raw'
# PowerShell's own parser consumes a literal "--" when binding arguments to a
# function: `function Show { $args }; Show -- --raw` arrives as one argument,
# "--raw". That happens before $args exists, so the wrapper cannot recover it
# and no wrapper can. The splatted array itself is forwarded faithfully: a real
# native command given @('--','--raw') receives both elements. The marker the
# wrapper writes still holds, which is the part under test.
assert_interpreter_ran "pwsh: pi with a user-supplied -- runs" &&
  assert_log_equals "pwsh: the function binder consumes the redundant --, the marker holds" \
    "$_spw_srt_log" srt command pi -- --raw

reset_logs
run_pwsh_case "$_spw_stub_bin" 'pi -c "echo hi"'
assert_interpreter_ran "pwsh: pi -c runs" &&
  assert_log_equals "pwsh: -c is not swallowed by srt" \
    "$_spw_srt_log" srt command pi -- -c "echo hi"

reset_logs
run_pwsh_case "$_spw_stub_bin" 'pi-unrestricted --version'
assert_interpreter_ran "pwsh: pi-unrestricted runs" &&
  assert_log_equals "pwsh: pi-unrestricted calls pi directly" \
    "$_spw_pi_log" pi-bin --version &&
  assert_log_empty "pwsh: pi-unrestricted never enters srt" "$_spw_srt_log"

# Every PATH entry carries its own pi under Nix, so Get-Command returns all of
# them. Without Select-Object -First 1 the array stringifies into a
# space-joined path and the call fails outright.
reset_logs
run_pwsh_case "$_spw_stub_bin:$_spw_stub_bin2" 'pi-unrestricted --help'
assert_interpreter_ran "pwsh: pi-unrestricted runs with pi on two PATH entries" &&
  assert_single_record "pwsh: pi-unrestricted invokes pi exactly once" "$_spw_pi_log" &&
  assert_log_equals "pwsh: pi-unrestricted picks the first pi on PATH" \
    "$_spw_pi_log" pi-bin --help &&
  assert_log_empty "pwsh: pi-unrestricted never enters srt with two PATH entries" "$_spw_srt_log"

# The same window flag as the zsh section: it has to reach srt's node without
# touching the caller's own NODE_OPTIONS.
reset_logs
run_pwsh_case "$_spw_stub_bin" 'pi --help'
assert_interpreter_ran "pwsh: pi runs with a clean NODE_OPTIONS" &&
  assert_log_equals "pwsh: pi hands srt the autoselect window flag" \
    "$_spw_srt_env_log" srt --network-family-autoselection-attempt-timeout=10000 &&
  assert_log_equals "pwsh: the flag leaves the forwarded argv unchanged" \
    "$_spw_srt_log" srt command pi -- --help

reset_logs
NODE_OPTIONS='--max-old-space-size=4096' run_pwsh_case "$_spw_stub_bin" 'pi --help'
assert_interpreter_ran "pwsh: pi runs with an inherited NODE_OPTIONS" &&
  assert_log_equals "pwsh: an inherited NODE_OPTIONS is prepended to, never replaced" \
    "$_spw_srt_env_log" srt '--max-old-space-size=4096 --network-family-autoselection-attempt-timeout=10000' &&
  assert_output_line "pwsh: the process-wide assignment is restored afterwards" \
    'node-options-after:--max-old-space-size=4096'

reset_logs
NODE_OPTIONS='--max-old-space-size=4096' run_pwsh_case "$_spw_stub_bin" 'pi-unrestricted --version'
assert_interpreter_ran "pwsh: pi-unrestricted runs with an inherited NODE_OPTIONS" &&
  assert_log_equals "pwsh: pi-unrestricted does not gain the sandbox flag" \
    "$_spw_pi_env_log" pi-bin '--max-old-space-size=4096' &&
  assert_log_equals "pwsh: pi-unrestricted still calls pi directly" \
    "$_spw_pi_log" pi-bin --version &&
  assert_log_empty "pwsh: pi-unrestricted never enters srt with the flag present" "$_spw_srt_log"

reset_logs
run_pwsh_case "$_spw_fail_bin" 'pi --help'
assert_exit_status "pwsh: pi preserves srt's exit status for the caller" 7
unset NODE_OPTIONS

finish_tests
