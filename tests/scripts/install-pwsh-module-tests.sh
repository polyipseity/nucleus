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
# red line, and a post-install listing fails the run when a copy survives
# beside the pin.
#
# Those three are asserted on the recorded program, which cannot tell a working
# program from a reordered one, so a second group runs the real thing. A stale
# copy with no PSGallery package record goes through a temp module root and real
# pwsh, and the post-install check goes through a harness whose session-scope
# functions shadow the cmdlets of the same name, the way Pester does it, so the
# check can be driven to both outcomes offline.
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

# The stale copy the harness reports: a version the program is not pinning, at a
# base path no real module has, so an assertion on the message can only match if
# the program named the copy it was actually shown.
IPM_FAKE_GUID='11111111-2222-3333-4444-555555555555'
IPM_FAKE_STALE_VERSION='1.0.0'
IPM_FAKE_STALE_BASE='/ipm-fake/ProbeMod/1.0.0'

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
# pwsh with PSModulePath pointed at MODULE_ROOT, which the pwsh child inherits.
# Sets RUN_STATUS, RUN_STDOUT and RUN_STDERR.
RUN_STATUS=0
RUN_STDOUT=''
RUN_STDERR=''
run_installer_real() {
  local module_root="$1"
  RUN_STATUS=0
  PSModulePath="$module_root" bash "$INSTALLER" "$(command -v pwsh)" "$2" "$3" \
    >"$TMP_DIR/real-out.txt" 2>"$TMP_DIR/real-err.txt" || RUN_STATUS=$?
  RUN_STDOUT="$(cat "$TMP_DIR/real-out.txt")"
  RUN_STDERR="$(cat "$TMP_DIR/real-err.txt")"
}

# The harness for the post-install check. Its functions shadow the cmdlets of the
# same name, so the recorded program runs with no module, no package record and
# no network, and the listing it sees is the one IPM_FAKE_POST_INSTALL asks for:
# 'leftover' keeps a stale copy visible after the install, anything else reports
# only the pin. The call log is what proves the install was attempted before the
# throw, which no assertion on the program's text can establish.
write_shadow_harness() {
  cat >"$TMP_DIR/shadow-harness.ps1" <<'HARNESS'
$script:ipmListCalls = 0

function Get-Module {
  param([switch]$ListAvailable, [string]$Name)
  # The program's other call asks whether the module is loaded, and in a fresh
  # session the answer is no, so only the listings are answered here.
  if (-not $ListAvailable) { return }
  $script:ipmListCalls++
  $stale = [PSCustomObject]@{
    Name = $Name
    Version = [Version]$env:IPM_FAKE_STALE_VERSION
    ModuleBase = $env:IPM_FAKE_STALE_BASE
  }
  $pin = [PSCustomObject]@{
    Name = $Name
    Version = [Version]$env:IPM_FAKE_PIN_VERSION
    ModuleBase = (Join-Path $env:IPM_FAKE_STALE_BASE 'pin')
  }
  if ($script:ipmListCalls -eq 1) { return ,@($stale) }
  if ($env:IPM_FAKE_POST_INSTALL -eq 'leftover') { return ,@($pin, $stale) }
  return ,@($pin)
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
    IPM_FAKE_STALE_VERSION="$IPM_FAKE_STALE_VERSION" \
    IPM_FAKE_STALE_BASE="$IPM_FAKE_STALE_BASE" \
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
  # The verification listing, the message that names the leftover, and the throw
  # that consumes it all have to sit after the install, or the check would read
  # the state from before it and the failure would never be raised. The message
  # and the throw share a line in the installer, so the throw is only required to
  # be at the message, not strictly after it.
  verify_line="$(last_line_of "$PS_LIST")"
  message_line="$(last_line_of 'other copies remain')"
  throw_line="$(last_line_of "throw ${PS}failure")"
  if [ "$listing_count" -ge 2 ] && [ "$verify_line" -gt "$install_line" ] &&
    [ "$message_line" -gt "$verify_line" ] && [ "$throw_line" -ge "$message_line" ]; then
    assert_pass "installer: re-lists after the install and throws when a copy survives"
  else
    assert_fail "installer: re-lists after the install and throws when a copy survives" "listings=$listing_count install=$install_line verify=$verify_line message=$message_line throw=$throw_line"
  fi
}

test_names_the_leftover_copy_in_the_failure() {
  run_installer Pester 6.2.0
  # The message has to carry the leftover's version and path, otherwise the
  # failure says a copy survived without saying which one.
  if grep -qF "${PS}_.Version" "$IPM_STUB_LOG" &&
    grep -qF "${PS}_.ModuleBase" "$IPM_STUB_LOG"; then
    assert_pass "installer: names the leftover copy's version and path in the failure"
  else
    assert_fail "installer: names the leftover copy's version and path in the failure" "recorded program: $(cat "$IPM_STUB_LOG")"
  fi
}

test_keeps_the_early_exit_when_the_pin_is_already_the_only_copy() {
  run_installer Pester 6.2.0
  local exit_line install_line
  exit_line="$(first_line_of 'is already the only copy')"
  install_line="$(first_line_of "$PS_INSTALL")"
  if [ "$exit_line" -gt 0 ] && [ "$exit_line" -lt "$install_line" ]; then
    assert_pass "installer: exits early when the pin is already the only copy"
  else
    assert_fail "installer: exits early when the pin is already the only copy" "early exit on line $exit_line, install on line $install_line"
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
test_keeps_the_early_exit_when_the_pin_is_already_the_only_copy
test_no_unannotated_suppression_in_the_installer
test_skips_pwsh_when_the_binary_is_not_executable
test_emits_the_program_without_shell_interpretation

section 2 "install-pwsh-module behaviour under real pwsh"

# The regression itself: a stale copy with no PSGallery package record used to be
# a red line, because Uninstall-Package could not find it and the install carried
# on beside it. That is the macOS runner's Pester 5.9.0.
test_stale_copy_with_no_package_record_fails_the_run() {
  local module_root="$TMP_DIR/stale-root"
  write_fake_module "$module_root" ProbeMod "$IPM_FAKE_STALE_VERSION"
  run_installer_real "$module_root" ProbeMod 2.0.0
  if [ "$RUN_STATUS" -eq 0 ]; then
    assert_fail "installer: a stale copy with no package record fails the run" "exited 0; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  # stderr has to name the module, or a non-zero status could be pwsh failing for
  # some unrelated reason and the case would pass for the wrong cause.
  if ! printf '%s' "$RUN_STDERR" | grep -qF 'ProbeMod'; then
    assert_fail "installer: a stale copy with no package record fails the run" "exited $RUN_STATUS without naming the module; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  # The load-bearing assertion, and the reason this case exists. Without the stop
  # the uninstall is a red line and the install carries on beside the stale copy,
  # so the run still ends non-zero, from the install failing with no network. The
  # exit status alone cannot tell the two apart, and the line the install prints is
  # what does.
  if printf '%s' "$RUN_STDOUT" | grep -qF 'installing'; then
    assert_fail "installer: a stale copy with no package record fails the run" "the install ran anyway, beside a copy the uninstall could not remove; stdout=$RUN_STDOUT"
    return
  fi
  assert_pass "installer: a stale copy with no package record fails the run"
}

# The pin alone is the state a converged host is in, and re-downloading it on
# every run is the cost the early exit exists to avoid.
test_pin_only_module_root_exits_zero_without_installing() {
  local module_root="$TMP_DIR/pin-root"
  write_fake_module "$module_root" ProbeMod 2.0.0
  run_installer_real "$module_root" ProbeMod 2.0.0
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_fail "installer: exits zero without installing when the pin is the only copy" "exited $RUN_STATUS; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDOUT" | grep -qF 'is already the only copy' &&
    ! printf '%s' "$RUN_STDOUT" | grep -qF 'installing'; then
    assert_pass "installer: exits zero without installing when the pin is the only copy"
  else
    assert_fail "installer: exits zero without installing when the pin is the only copy" "stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

# The post-install check, driven to the outcome where a copy survived it. A
# module Uninstall-Package cannot see survives the removal, which is how an
# image-baked copy behaves.
test_post_install_check_throws_and_names_the_surviving_copy() {
  run_shadowed_program ProbeMod 2.0.0 leftover
  if [ "$RUN_STATUS" -eq 0 ]; then
    assert_fail "installer: the post-install check throws and names the surviving copy" "exited 0; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDERR" | grep -qF "$IPM_FAKE_STALE_VERSION" &&
    printf '%s' "$RUN_STDERR" | grep -qF "$IPM_FAKE_STALE_BASE"; then
    assert_pass "installer: the post-install check throws and names the surviving copy"
  else
    assert_fail "installer: the post-install check throws and names the surviving copy" "exited $RUN_STATUS without naming $IPM_FAKE_STALE_VERSION at $IPM_FAKE_STALE_BASE; stderr=$RUN_STDERR"
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

# The same harness with the leftover gone. Without this the case above could be
# passing because the check always throws, which is the opposite of a check.
test_post_install_check_passes_when_only_the_pin_is_left() {
  run_shadowed_program ProbeMod 2.0.0 clean
  if [ "$RUN_STATUS" -ne 0 ]; then
    assert_fail "installer: the post-install check passes when only the pin is left" "exited $RUN_STATUS; stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    return
  fi
  if printf '%s' "$RUN_STDOUT" | grep -qF 'is the only copy'; then
    assert_pass "installer: the post-install check passes when only the pin is left"
  else
    assert_fail "installer: the post-install check passes when only the pin is left" "stdout=$RUN_STDOUT stderr=$RUN_STDERR"
  fi
}

test_stale_copy_with_no_package_record_fails_the_run
test_pin_only_module_root_exits_zero_without_installing
test_post_install_check_throws_and_names_the_surviving_copy
test_post_install_check_reads_the_state_left_by_the_install
test_post_install_check_passes_when_only_the_pin_is_left

finish_tests
