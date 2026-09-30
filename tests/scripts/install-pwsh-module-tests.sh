#!/usr/bin/env bash
# Tests for src/scripts/packages/install-pwsh-module.sh.
#
# The installer takes the pwsh binary as its first argument and hands one
# inline PowerShell program to it, so every assertion here is made on the
# program that was recorded, not on PowerShell's behaviour: what the program was
# told to do, in what order, and with which error handling.
#
# The three properties under test are the ones whose absence let Pester 5.9.0
# and 6.2.0 sit side by side on the macOS CI runner: the module is unloaded
# before it is uninstalled, the uninstall stops on error instead of printing a
# red line, and a post-install listing fails the run when a copy that can shadow
# the pin survives it.
#
# Which copies those are is the rule the runner turned red over. PowerShell loads
# the highest version available, so a copy below the pin is inert and is left
# alone; a copy at or above the pin, at any scope, is a target, because a tie on
# version is broken by path order. The early exit has to name both facts
# separately, since nothing shadowing the pin is also true on a host that has no
# pin at all.
#
# Those three are asserted on the recorded program, which cannot tell a working
# program from a reordered one, so a second group runs the real thing. A copy
# outside the per-user module path with no PSGallery package record goes through a
# temp module root and real pwsh, and the post-install check goes through a
# harness whose session-scope functions shadow the cmdlets of the same name, the
# way Pester does it, so the check can be driven to both outcomes offline.
#
# Run with: bash tests/scripts/install-pwsh-module-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT

# WHY required rather than stubbed: the second group runs the emitted program, and
#   a stub could only re-state what the first group already asserts.
require_command pwsh "install-pwsh-module: the emitted PowerShell program runs under real pwsh"

INSTALLER="$REPO_ROOT/src/scripts/packages/install-pwsh-module.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Where a CurrentUser install lands, and why the tests have to ask rather than
# assume: pwsh rebuilds PSModulePath from HOME instead of inheriting it, so the
# env var a case sets comes out last. Pointing HOME at a temp home both isolates
# the run from the developer's own modules and puts the per-user module path the
# program reads first at a place the suite may write to. Copies the program is
# meant to see as belonging to someone else go in the extra root instead, which
# is where the env var lands.
IPM_TEST_HOME="$TMP_DIR/home"
mkdir -p "$IPM_TEST_HOME"
IPM_USER_MODULE_ROOT="$(
  # shellcheck disable=SC2016 # reason: a PowerShell program is handed to pwsh verbatim, bash must not expand its sigils
  HOME="$IPM_TEST_HOME" PSModulePath="$TMP_DIR" \
    pwsh -NoProfile -Command '@($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })[0]'
)"

# Recording stand-in for pwsh. It logs the inline program it was handed and
# exits with $IPM_STUB_EXIT, so a case can prove that a pwsh failure reaches
# the caller as this script's exit status.
cat >"$TMP_DIR/pwsh-stub" <<'STUB'
#!/usr/bin/env bash
# The installer passes -NoProfile, -Command, then the inline program.
printf '%s\n' "$3" >"${IPM_STUB_LOG:?IPM_STUB_LOG must name the log file}"
exit "${IPM_STUB_EXIT:-0}"
STUB
chmod +x "$TMP_DIR/pwsh-stub"

export IPM_STUB_LOG="$TMP_DIR/recorded-program.ps1"
export IPM_STUB_EXIT=0

# The copy the harness reports: a version at or above the pin, at a base path no
# real module has, so an assertion on the message can only match if the program
# named the copy it was actually shown.
IPM_FAKE_GUID='11111111-2222-3333-4444-555555555555'
IPM_FAKE_SHADOW_VERSION='3.0.0'
IPM_FAKE_SHADOW_BASE='/ipm-fake/ProbeMod/3.0.0'
# The per-user module path the program derives from PSModulePath. The harness
# points PSModulePath at it so the pin it reports sits under the path the
# program calls converged, the way a CurrentUser install does.
IPM_FAKE_USER_PATH='/ipm-fake/user-modules'
# A copy below the pin, which PowerShell never loads in its favour. The pin used
# by the behavioural cases is 2.0.0, so 1.0.0 is inert and must not fail the run.
IPM_FAKE_LOWER_VERSION='1.0.0'
IPM_FAKE_LOWER_BASE='/ipm-fake/ProbeMod/1.0.0'

# The installer emits a PowerShell program, so every pattern matched below has
# to carry PowerShell's sigil. Building it once keeps the patterns readable
# without writing a literal sigil into a single-quoted shell string, which the
# linter reports as an unexpanded expression.
PS='$'

# The calls the assertions match on, spelled the way the program spells them.
PS_UNLOAD="Remove-Module -Name ${PS}moduleName"
PS_UNINSTALL="Uninstall-Module -Name ${PS}moduleName"
PS_INSTALL="Install-Module -Name ${PS}moduleName"
PS_LIST="Get-Module -ListAvailable -Name ${PS}moduleName"
PS_LOADED_GUARD="if (Get-Module -Name ${PS}moduleName)"

# run_installer MODULE VERSION: run the installer against the stand-in and
# leave the recorded program in IPM_STUB_LOG. Sets RUN_STATUS to the installer's
# exit status.
RUN_STATUS=0
RUN_STUB_STDERR=''
run_installer() {
  : >"$IPM_STUB_LOG"
  RUN_STUB_STDERR=''
  bash "$INSTALLER" "$TMP_DIR/pwsh-stub" "$1" "$2" 2>"$TMP_DIR/stub-err.txt" || RUN_STATUS=$?
  RUN_STUB_STDERR="$(cat "$TMP_DIR/stub-err.txt")"
}

# first_line_of PATTERN: print the 1-based line number of the first line
# containing PATTERN, or 0 when there is none.
first_line_of() {
  awk -v pat="$1" 'index($0, pat) { print NR; exit }' "$IPM_STUB_LOG"
}

# last_line_of PATTERN: print the 1-based line number of the last line
# containing PATTERN, or 0 when there is none.
last_line_of() {
  awk -v pat="$1" '{ if (index($0, pat)) { line = NR } } END { print line + 0 }' "$IPM_STUB_LOG"
}

# count_of PATTERN: print how many lines contain PATTERN.
count_of() {
  awk -v pat="$1" '{ if (index($0, pat)) { n++ } } END { print n + 0 }' "$IPM_STUB_LOG"
}

# write_fake_module ROOT NAME VERSION: lay out a module under a module root so
# Get-Module -ListAvailable reports it. It has no PSGallery package record,
# which is the point: that is what an image-baked copy looks like.
write_fake_module() {
  local root="$1" name="$2" version="$3" dir
  dir="$root/$name/$version"
  mkdir -p "$dir"
  cat >"$dir/$name.psd1" <<MANIFEST
@{
  ModuleVersion = '$version'
  GUID = '$IPM_FAKE_GUID'
  Author = 'install-pwsh-module test'
  RootModule = ''
  FunctionsToExport = @()
  CmdletsToExport = @()
  VariablesToExport = @()
  AliasesToExport = @()
}
MANIFEST
}

# run_installer_real MODULE_ROOT MODULE VERSION: run the installer under real
# pwsh with MODULE_ROOT as the extra path a copy the program does not own lives
# in. pwsh rebuilds PSModulePath from HOME and appends that extra path last, so a
# pin has to be laid out under IPM_USER_MODULE_ROOT to count as converged.
# Sets RUN_STATUS, RUN_STDOUT and RUN_STDERR.
RUN_STATUS=0
RUN_STDOUT=''
RUN_STDERR=''
run_installer_real() {
  local module_root="$1"
  RUN_STATUS=0
  HOME="$IPM_TEST_HOME" PSModulePath="$module_root" bash "$INSTALLER" "$(command -v pwsh)" "$2" "$3" \
    >"$TMP_DIR/real-out.txt" 2>"$TMP_DIR/real-err.txt" || RUN_STATUS=$?
  RUN_STDOUT="$(cat "$TMP_DIR/real-out.txt")"
  RUN_STDERR="$(cat "$TMP_DIR/real-err.txt")"
}

# The harness for the post-install check. Its functions shadow the cmdlets of the
# same name, so the recorded program runs with no module, no package record and
# no network, and the listing it sees is the one IPM_FAKE_POST_INSTALL asks for:
# 'leftover' keeps a copy that can shadow the pin visible after the install,
# anything else reports only the pin. The call log is what proves the install was
# attempted before the throw, which no assertion on the program's text can
# establish.
write_shadow_harness() {
  cat >"$TMP_DIR/shadow-harness.ps1" <<'HARNESS'
$script:ipmListCalls = 0

# The program reads PSModulePath to find the per-user module path, so it has to
# point at the root the fake pin is laid out under.
$env:PSModulePath = $env:IPM_FAKE_USER_PATH

function Get-Module {
  param([switch]$ListAvailable, [string]$Name)
  # The program's other call asks whether the module is loaded, and in a fresh
  # session the answer is no, so only the listings are answered here.
  if (-not $ListAvailable) { return }
  $script:ipmListCalls++
  $shadow = [PSCustomObject]@{
    Name = $Name
    Version = [Version]$env:IPM_FAKE_SHADOW_VERSION
    ModuleBase = $env:IPM_FAKE_SHADOW_BASE
  }
  $pin = [PSCustomObject]@{
    Name = $Name
    Version = [Version]$env:IPM_FAKE_PIN_VERSION
    ModuleBase = (Join-Path $env:IPM_FAKE_USER_PATH ($Name + '/' + $env:IPM_FAKE_PIN_VERSION))
  }
  $lower = [PSCustomObject]@{
    Name = $Name
    Version = [Version]$env:IPM_FAKE_LOWER_VERSION
    ModuleBase = $env:IPM_FAKE_LOWER_BASE
  }
  # WHY no wrapping comma on the returns: a unary comma emits the array as one
  #   pipeline object, so the program's own @() around the call would collect a
  #   single element that happens to be an array, and every filter downstream
  #   would see one object whose properties enumerate to both copies.
  if ($script:ipmListCalls -eq 1) { return @($shadow) }
  if ($env:IPM_FAKE_POST_INSTALL -eq 'leftover') { return @($pin, $shadow) }
  if ($env:IPM_FAKE_POST_INSTALL -eq 'lower') { return @($pin, $lower) }
  return @($pin)
}

function Uninstall-Module {
  [CmdletBinding()]
  param([string]$Name, [switch]$AllVersions, [switch]$Force)
  Add-Content -Path $env:IPM_CALL_LOG -Value "uninstall $Name"
}

function Install-Module {
  [CmdletBinding()]
  param([string]$Name, [Version]$RequiredVersion, [switch]$Force, [string]$Scope, [switch]$AllowClobber)
  Add-Content -Path $env:IPM_CALL_LOG -Value "install $RequiredVersion"
}

function Remove-Module {
  [CmdletBinding()]
  param([string]$Name, [switch]$Force)
  Add-Content -Path $env:IPM_CALL_LOG -Value "remove $Name"
}

. $env:IPM_FAKE_PROGRAM
HARNESS
}

# run_shadowed_program MODULE VERSION POST_INSTALL_STATE: record the program the
# installer hands pwsh, then run it through the harness. Sets RUN_STATUS,
# RUN_STDOUT, RUN_STDERR and RUN_CALLS.
RUN_CALLS=''
run_shadowed_program() {
  run_installer "$1" "$2"
  cp "$IPM_STUB_LOG" "$TMP_DIR/recorded-for-harness.ps1"
  write_shadow_harness
  : >"$TMP_DIR/calls.log"
  RUN_STATUS=0
  IPM_FAKE_PROGRAM="$TMP_DIR/recorded-for-harness.ps1" \
    IPM_FAKE_MODULE="$1" \
    IPM_FAKE_PIN_VERSION="$2" \
    IPM_FAKE_SHADOW_VERSION="$IPM_FAKE_SHADOW_VERSION" \
    IPM_FAKE_SHADOW_BASE="$IPM_FAKE_SHADOW_BASE" \
    IPM_FAKE_USER_PATH="$IPM_FAKE_USER_PATH" \
    IPM_FAKE_LOWER_VERSION="$IPM_FAKE_LOWER_VERSION" \
    IPM_FAKE_LOWER_BASE="$IPM_FAKE_LOWER_BASE" \
    IPM_FAKE_POST_INSTALL="$3" \
    IPM_CALL_LOG="$TMP_DIR/calls.log" \
    pwsh -NoProfile -File "$TMP_DIR/shadow-harness.ps1" \
    >"$TMP_DIR/shadow-out.txt" 2>"$TMP_DIR/shadow-err.txt" || RUN_STATUS=$?
  RUN_STDOUT="$(cat "$TMP_DIR/shadow-out.txt")"
  RUN_STDERR="$(cat "$TMP_DIR/shadow-err.txt")"
  RUN_CALLS="$(cat "$TMP_DIR/calls.log")"
}

section 1 "install-pwsh-module program contract"

test_records_pinned_module_and_version() {
  run_installer Pester 6.2.0
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_fail "installer: hands pwsh the pinned module and version" "installer exited $RUN_STATUS"
    return
  fi
  if grep -qF "${PS}moduleName = 'Pester'" "$IPM_STUB_LOG" &&
    grep -qF "${PS}requiredVersion = [Version]'6.2.0'" "$IPM_STUB_LOG"; then
    assert_pass "installer: hands pwsh the pinned module and version"
  else
    assert_fail "installer: hands pwsh the pinned module and version" "recorded program: $(cat "$IPM_STUB_LOG")"
  fi
}

test_unloads_module_before_uninstalling() {
  run_installer Pester 6.2.0
  local unload_line uninstall_line
  unload_line="$(first_line_of "$PS_UNLOAD")"
  uninstall_line="$(first_line_of "$PS_UNINSTALL")"
  if [ "$unload_line" -eq 0 ] || [ "$uninstall_line" -eq 0 ]; then
    assert_fail "installer: unloads the module before uninstalling it" "no Remove-Module or Uninstall-Module in the recorded program"
    return
  fi
  if [ "$unload_line" -lt "$uninstall_line" ]; then
    assert_pass "installer: unloads the module before uninstalling it"
  else
    assert_fail "installer: unloads the module before uninstalling it" "Remove-Module on line $unload_line, Uninstall-Module on line $uninstall_line"
  fi
}

test_unload_only_runs_when_module_is_loaded() {
  run_installer Pester 6.2.0
  local guard_line unload_line
  unload_line="$(first_line_of "$PS_UNLOAD")"
  guard_line="$(first_line_of "$PS_LOADED_GUARD")"
  # The guard has to open the line above the unload, so the unload is inside
  # that if block and runs only when a copy is actually loaded. An unload with
  # no guard is the case that needs an error suppression to stay quiet.
  if [ "$guard_line" -gt 0 ] && [ "$((guard_line + 1))" -eq "$unload_line" ]; then
    assert_pass "installer: unloads only when a copy is loaded, with nothing to suppress"
  else
    assert_fail "installer: unloads only when a copy is loaded, with nothing to suppress" "guard on line $guard_line, unload on line $unload_line"
  fi
}

test_uninstall_stops_on_error() {
  run_installer Pester 6.2.0
  if grep -F "$PS_UNINSTALL" "$IPM_STUB_LOG" | grep -qF -- '-ErrorAction Stop'; then
    assert_pass "installer: uninstalls with -ErrorAction Stop so a refusal is a failure"
  else
    assert_fail "installer: uninstalls with -ErrorAction Stop so a refusal is a failure" "recorded program: $(cat "$IPM_STUB_LOG")"
  fi
}

test_pwsh_failure_reaches_the_caller() {
  IPM_STUB_EXIT=1
  run_installer Pester 6.2.0
  IPM_STUB_EXIT=0
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_pass "installer: propagates a pwsh failure as a non-zero exit"
  else
    assert_fail "installer: propagates a pwsh failure as a non-zero exit" "installer exited 0 after pwsh exited 1"
  fi
}

test_verifies_the_pin_is_the_only_copy_after_installing() {
  run_installer Pester 6.2.0
  local install_line listing_count verify_line message_line throw_line
  install_line="$(first_line_of "$PS_INSTALL")"
  listing_count="$(count_of "$PS_LIST")"
  # The verification listing, the message that names the copy that could shadow
  # the pin, and the throw that consumes it all have to sit after the install, or
  # the check would read the state from before it and the failure would never be
  # raised. The message and the throw share a line in the installer, so the throw
  # is only required to be at the message, not strictly after it.
  verify_line="$(last_line_of "$PS_LIST")"
  message_line="$(last_line_of 'other copies remain')"
  throw_line="$(last_line_of "throw ${PS}failure")"
  if [ "$listing_count" -ge 2 ] && [ "$verify_line" -gt "$install_line" ] &&
    [ "$message_line" -gt "$verify_line" ] && [ "$throw_line" -ge "$message_line" ]; then
    assert_pass "installer: re-lists after the install and throws when a copy can shadow the pin"
  else
    assert_fail "installer: re-lists after the install and throws when a copy can shadow the pin" "listings=$listing_count install=$install_line verify=$verify_line message=$message_line throw=$throw_line"
  fi
}

test_names_the_leftover_copy_in_the_failure() {
  run_installer Pester 6.2.0
  # The message has to carry the copy's version and path, otherwise the failure
  # says a copy survived without saying which one.
  if grep -qF "${PS}_.Version" "$IPM_STUB_LOG" &&
    grep -qF "${PS}_.ModuleBase" "$IPM_STUB_LOG"; then
    assert_pass "installer: names the copy that survived's version and path in the failure"
  else
    assert_fail "installer: names the copy that survived's version and path in the failure" "recorded program: $(cat "$IPM_STUB_LOG")"
  fi
}

test_keeps_the_early_exit_when_the_pin_is_already_converged() {
  run_installer Pester 6.2.0
  local exit_line install_line
  exit_line="$(first_line_of 'is already converged')"
  install_line="$(first_line_of "$PS_INSTALL")"
  if [ "$exit_line" -gt 0 ] && [ "$exit_line" -lt "$install_line" ]; then
    assert_pass "installer: exits early when the pin is already converged"
  else
    assert_fail "installer: exits early when the pin is already converged" "early exit on line $exit_line, install on line $install_line"
  fi
}

# The early exit has to test the pin being present and nothing shadowing it as
# two facts. A single predicate over "no copy can shadow the pin" is also true on
# a host that has no pin at all, and that host would then never get one.
test_early_exit_names_the_pin_and_the_shadowing_separately() {
  run_installer Pester 6.2.0
  if grep -qF "if (${PS}converged.Count -gt 0 -and ${PS}shadowing.Count -eq 0)" "$IPM_STUB_LOG"; then
    assert_pass "installer: the early exit requires both the pin and the absence of anything shadowing it"
  else
    assert_fail "installer: the early exit requires both the pin and the absence of anything shadowing it" "recorded program: $(cat "$IPM_STUB_LOG")"
  fi
}

test_no_unannotated_suppression_in_the_installer() {
  # Counted with awk rather than grep: grep exits 1 on no match, and under
  # set -e that would abort the case before it could report the pass.
  local hits
  hits="$(awk '/\|\| true|2>\/dev\/null|-ErrorAction SilentlyContinue/ { n++ } END { print n + 0 }' "$INSTALLER")"
  if [ "$hits" -eq 0 ]; then
    assert_pass "installer: carries no error suppression"
  else
    assert_fail "installer: carries no error suppression" "$hits suppression line(s) found"
  fi
}

test_skips_pwsh_when_the_binary_is_not_executable() {
  : >"$IPM_STUB_LOG"
  RUN_STATUS=0
  bash "$INSTALLER" "$TMP_DIR/not-a-pwsh" Pester 6.2.0 || RUN_STATUS=$?
  if [ "$RUN_STATUS" -eq 0 ] && [ ! -s "$IPM_STUB_LOG" ]; then
    assert_pass "installer: no-ops without running pwsh when the binary is missing"
  else
    assert_fail "installer: no-ops without running pwsh when the binary is missing" "exit=$RUN_STATUS, recorded=$(wc -c <"$IPM_STUB_LOG" | tr -d ' ') bytes"
  fi
}

# The program is handed to pwsh inside a double-quoted bash string, so a
# backtick or a $( anywhere in it is expanded by the shell before PowerShell ever
# reads it. A backtick around one word in a comment was silently executed as a
# command, and the comment arrived with the word gone. Nothing else in this suite
# would notice, because a mangled comment changes no behaviour.
test_emits_the_program_without_shell_interpretation() {
  run_installer Pester 6.2.0
  if [ -n "$RUN_STUB_STDERR" ]; then
    assert_fail "installer: hands pwsh the program with nothing the shell interpreted" "the shell wrote to stderr while building the program: $RUN_STUB_STDERR"
    return
  fi
  if grep -qE '`|\$\(' "$IPM_STUB_LOG"; then
    assert_fail "installer: hands pwsh the program with nothing the shell interpreted" "the recorded program still holds a substitution the shell would have eaten: $(grep -nE '\`|\$\(' "$IPM_STUB_LOG")"
    return
  fi
  assert_pass "installer: hands pwsh the program with nothing the shell interpreted"
}

test_records_pinned_module_and_version
test_unloads_module_before_uninstalling
test_unload_only_runs_when_module_is_loaded
test_uninstall_stops_on_error
test_pwsh_failure_reaches_the_caller
test_verifies_the_pin_is_the_only_copy_after_installing
test_names_the_leftover_copy_in_the_failure
test_keeps_the_early_exit_when_the_pin_is_already_converged
test_early_exit_names_the_pin_and_the_shadowing_separately
test_no_unannotated_suppression_in_the_installer
test_skips_pwsh_when_the_binary_is_not_executable
test_emits_the_program_without_shell_interpretation

section 2 "install-pwsh-module behaviour under real pwsh"

# A lower copy is inert, because PowerShell loads the highest version available,
# but it is not a reason to believe the pin is in place. This is the host that
# makes the early exit worth testing: nothing shadows the pin and the pin is
# absent, so a single predicate over the shadowing set would read it as
# converged and leave the host without the module it was asked for.
test_only_a_lower_copy_still_attempts_the_install() {
  local module_root="$TMP_DIR/lower-only-root"
  write_fake_module "$module_root" ProbeMod 1.0.0
  run_installer_real "$module_root" ProbeMod 2.0.0
  if printf '%s' "$RUN_STDOUT" | grep -qF 'installing'; then
    assert_pass "installer: a host holding only a lower copy still attempts the install"
  else
    assert_fail "installer: a host holding only a lower copy still attempts the install" "the install was skipped; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

# The rule the change exists for. 1.0.0 beside the 2.0.0 pin is the CI runner's
# Pester 5.9.0, and treating it as a target is what turned that runner red. A
# target predicate of "version differs from the pin" sweeps it and fails, so this
# case is the one that discriminates between the two predicates.
test_copy_below_the_pin_beside_the_pin_exits_zero() {
  local module_root="$TMP_DIR/below-pin-root"
  write_fake_module "$module_root" ProbeMod 1.0.0
  write_fake_module "$IPM_USER_MODULE_ROOT" ProbeMod 2.0.0
  run_installer_real "$module_root" ProbeMod 2.0.0
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_fail "installer: exits zero when a copy below the pin sits beside it" "exited $RUN_STATUS; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDOUT" | grep -qF 'is already converged' &&
    ! printf '%s' "$RUN_STDOUT" | grep -qF 'removing'; then
    assert_pass "installer: exits zero when a copy below the pin sits beside it"
  else
    assert_fail "installer: exits zero when a copy below the pin sits beside it" "stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

# The other side of the same boundary, and the reason the check above is a rule
# rather than a switch being turned off. Three copies straddle the pin: only the
# one above it is swept, so the count in the message is the assertion that
# separates 3.0.0 and 2.0.0 from 1.0.0. The sweep then stops on the refusal that
# has no PSGallery package record behind it, which is what fails the run.
test_copy_above_the_pin_is_swept_and_the_run_fails() {
  local module_root="$TMP_DIR/above-pin-root"
  write_fake_module "$module_root" ProbeMod 1.0.0
  write_fake_module "$module_root" ProbeMod 3.0.0
  write_fake_module "$IPM_USER_MODULE_ROOT" ProbeMod 2.0.0
  run_installer_real "$module_root" ProbeMod 2.0.0
  if [ "$RUN_STATUS" -eq 0 ]; then
    assert_fail "installer: a copy above the pin is swept and the run fails" "exited 0; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if ! printf '%s' "$RUN_STDOUT" | grep -qF 'removing 1 conflicting ProbeMod version(s)'; then
    assert_fail "installer: a copy above the pin is swept and the run fails" "the sweep did not name exactly the one copy above the pin; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  # Without this the case could be passing on a sweep of all three copies, which
  # is the behaviour the rule change removed.
  if printf '%s' "$RUN_STDOUT" | grep -qF 'installing'; then
    assert_fail "installer: a copy above the pin is swept and the run fails" "the install carried on beside the copy the sweep could not remove; stdout=$RUN_STDOUT"
    return
  fi
  # stderr has to name the module, or a non-zero status could be pwsh failing for
  # some unrelated reason and the case would pass for the wrong cause.
  if printf '%s' "$RUN_STDERR" | grep -qF 'ProbeMod'; then
    assert_pass "installer: a copy above the pin is swept and the run fails"
  else
    assert_fail "installer: a copy above the pin is swept and the run fails" "exited $RUN_STATUS without naming the module; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

# The pin alone is the state a converged host is in, and re-downloading it on
# every run is the cost the early exit exists to avoid.
test_pin_only_module_root_exits_zero_without_installing() {
  write_fake_module "$IPM_USER_MODULE_ROOT" ProbeMod 2.0.0
  run_installer_real "$TMP_DIR/empty-root" ProbeMod 2.0.0
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_fail "installer: exits zero without installing when the pin is the only copy" "exited $RUN_STATUS; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDOUT" | grep -qF 'is already converged' &&
    ! printf '%s' "$RUN_STDOUT" | grep -qF 'installing'; then
    assert_pass "installer: exits zero without installing when the pin is the only copy"
  else
    assert_fail "installer: exits zero without installing when the pin is the only copy" "stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

# The post-install check, driven to the outcome where a copy that could shadow
# the pin survived it. A copy Uninstall-Package cannot see is the image-baked one,
# and a copy of the pin at a scope the program does not own is the other, since a
# tie on version goes to whichever path comes first.
test_post_install_check_throws_and_names_the_surviving_copy() {
  run_shadowed_program ProbeMod 2.0.0 leftover
  if [ "$RUN_STATUS" -eq 0 ]; then
    assert_fail "installer: the post-install check throws and names the surviving copy" "exited 0; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDERR" | grep -qF "$IPM_FAKE_SHADOW_VERSION" &&
    printf '%s' "$RUN_STDERR" | grep -qF "$IPM_FAKE_SHADOW_BASE"; then
    assert_pass "installer: the post-install check throws and names the surviving copy"
  else
    assert_fail "installer: the post-install check throws and names the surviving copy" "exited $RUN_STATUS without naming $IPM_FAKE_SHADOW_VERSION at $IPM_FAKE_SHADOW_BASE; stderr=$RUN_STDERR"
  fi
}

# The ordering the text assertions cannot make: the check has to read the state
# left by the install, so the install has to have happened before the throw.
test_post_install_check_reads_the_state_left_by_the_install() {
  run_shadowed_program ProbeMod 2.0.0 leftover
  if printf '%s' "$RUN_CALLS" | grep -qF 'install 2.0.0'; then
    assert_pass "installer: the post-install check reads the state left by the install"
  else
    assert_fail "installer: the post-install check reads the state left by the install" "recorded calls: [$RUN_CALLS] stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

# The same harness with the copy that could shadow the pin gone. Without this
# the case above could be passing because the check always throws, which is the
# opposite of a check.
test_post_install_check_passes_when_a_lower_copy_survives() {
  run_shadowed_program ProbeMod 2.0.0 lower
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_fail "installer: a copy below the pin does not fail the post-install check" "exited $RUN_STATUS; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDOUT" | grep -qF 'no copy can shadow it'; then
    assert_pass "installer: a copy below the pin does not fail the post-install check"
  else
    assert_fail "installer: a copy below the pin does not fail the post-install check" "stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

test_post_install_check_passes_when_only_the_pin_is_left() {
  run_shadowed_program ProbeMod 2.0.0 clean
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_fail "installer: the post-install check passes when only the pin is left" "exited $RUN_STATUS; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDOUT" | grep -qF 'no copy can shadow it'; then
    assert_pass "installer: the post-install check passes when only the pin is left"
  else
    assert_fail "installer: the post-install check passes when only the pin is left" "stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

test_only_a_lower_copy_still_attempts_the_install
test_copy_below_the_pin_beside_the_pin_exits_zero
test_copy_above_the_pin_is_swept_and_the_run_fails
test_pin_only_module_root_exits_zero_without_installing
test_post_install_check_throws_and_names_the_surviving_copy
test_post_install_check_reads_the_state_left_by_the_install
test_post_install_check_passes_when_only_the_pin_is_left
test_post_install_check_passes_when_a_lower_copy_survives

finish_tests
