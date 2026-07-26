#!/usr/bin/env bash
# Tests for PSScriptAnalyzer warmup behavior.
#
# Verifies that:
#   1. -SyntaxOnly skips lint (exit 0, lint skipped message)
#   2. Default mode (with warmup) completes without unhandled errors
#   3. Warmup message is printed (notably absent from output — silent)
#
# These tests complement the existing Step 3 (PowerShell lint) in test.sh.
#
# Dependencies: pwsh, PSScriptAnalyzer module.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

cd "$REPO_ROOT"

CHECK_PWSH="scripts/check-pwsh.ps1"

# Pre-flight: skip all tests if pwsh or PSScriptAnalyzer is unavailable.
if ! command -v pwsh &>/dev/null; then
  echo -e "\033[1;33m⊘\033[0m All tests skipped: pwsh not found"
  exit 0
fi

# shellcheck disable=SC2016 # reason: PowerShell syntax $true/$_ inside single quotes, not shell variables
if ! pwsh -NoLogo -NoProfile -NonInteractive -Command '& { exit (Get-Module -ListAvailable -Name PSScriptAnalyzer ? { $true } ? { 0 } : { 1 }) }' 2>/dev/null; then
  echo -e "\033[1;33m⊘\033[0m All tests skipped: PSScriptAnalyzer not installed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Test 1: -SyntaxOnly must skip lint (exit 0) and print skip message.
# ---------------------------------------------------------------------------
echo "--- Test 1: -SyntaxOnly behavior ---"

# check-suppress:suppression_doc: || true prevents set -e abort when pwsh exits non-zero; exit code is checked explicitly via assert_fail
_syntax_output=$(pwsh -NoLogo -NoProfile -NonInteractive -File "$CHECK_PWSH" -SyntaxOnly 2>&1 || true)

if echo "$_syntax_output" | grep -q 'PowerShell lint skipped'; then
  assert_pass "SyntaxOnly: prints lint skipped message"
else
  assert_fail "SyntaxOnly: prints lint skipped message" "Expected 'PowerShell lint skipped' in output"
fi

# ---------------------------------------------------------------------------
# Test 2: Default mode (with warmup) completes without errors
#         and produces diagnostics.
# ---------------------------------------------------------------------------
echo "--- Test 2: Default mode (with warmup) ---"

set +e
_default_output=$(pwsh -NoLogo -NoProfile -NonInteractive -File "$CHECK_PWSH" 2>&1)
_default_exit=$?
set -e

# Count diagnostic lines (format: file:line:col: [Severity] Message)
_default_diag=$(echo "$_default_output" | grep -Ec '\.ps1:[0-9]+:[0-9]+: \[' 2>/dev/null || echo "0")

if [ "$_default_exit" -ne 0 ]; then
  assert_pass "Default mode: exits non-zero (expected, lint issues exist)"
else
  assert_fail "Default mode: exits non-zero" "Expected exit != 0 (lint issues should exist). Exit code: $_default_exit"
fi

if [ "$_default_diag" -gt 0 ]; then
  assert_pass "Default mode: produces $_default_diag diagnostics"
else
  assert_fail "Default mode: produces diagnostics" "Expected at least 1 diagnostic, got $_default_diag"
fi

# Check for unhandled exception messages (would indicate a bug)
if echo "$_default_output" | grep -qi 'RuntimeException\|NullReferenceException\|MethodInvocationException'; then
  assert_fail "Default mode: no unhandled exceptions" "Found unexpected exception in output"
else
  assert_pass "Default mode: no unhandled exceptions"
fi

# ---------------------------------------------------------------------------
# Test 3: Warmup is silent (no error messages from the trivial invocation).
# ---------------------------------------------------------------------------
echo "--- Test 3: Warmup silent ---"

# The warmup ('1+1') should not produce any crash-level error output.
# Exclude the deliberate 'PowerShell lint check failed.' throw from check-pwsh.ps1.
# grep for actual runtime exceptions that would indicate a bug in the warmup.
if echo "$_default_output" | grep -qi 'NullReferenceException\|RuntimeException\|MethodInvocationException\|Cannot bind argument'; then
  assert_fail "Warmup: no runtime exceptions" "Found unexpected exception in output"
else
  assert_pass "Warmup: no runtime exceptions from trivial invocation"
fi

# ---------------------------------------------------------------------------
# Test 4: Direct function dot-source works (standalone invocation).
# ---------------------------------------------------------------------------
echo "--- Test 4: Dot-source function ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($rp, $env, $result) inside single-quoted -Command, not shell variables
_dot_source_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = $env:NUCLEUS_TEST_ROOT
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  Import-Module PSScriptAnalyzer
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  $result = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1"
  Write-Output "INJECTED=$($result.InjectedNameCount)"
' 2>&1)
_dot_source_exit=$?
set -e

if [ "$_dot_source_exit" -eq 0 ]; then
  assert_pass "Dot-source: function executes without error"
else
  assert_fail "Dot-source: function executes without error" "Exit code: $_dot_source_exit, Output: $_dot_source_out"
fi

if echo "$_dot_source_out" | grep -q '^INJECTED=[1-9]'; then
  assert_pass "Dot-source: injected at least one command name (INJECTED=$_dot_source_exit)"
else
  assert_fail "Dot-source: injected at least one command name" "Expected INJECTED=N with N>0, got: $_dot_source_out"
fi

if echo "$_dot_source_out" | grep -qi 'NullReferenceException\|RuntimeException'; then
  assert_fail "Dot-source: no exceptions" "Found unexpected exception in output"
else
  assert_pass "Dot-source: no exceptions"
fi

# ---------------------------------------------------------------------------
# Test 5: Injection does not suppress real diagnostics.
#         Running lint on a file with known issues should still produce
#         diagnostics even after cache pre-population.
# ---------------------------------------------------------------------------
echo "--- Test 5: Injection preserves real diagnostics ---"

set +e
_diag_output=$(pwsh -NoLogo -NoProfile -NonInteractive -File "$CHECK_PWSH" 2>&1)
_diag_exit=$?
set -e

_diag_count=$(echo "$_diag_output" | grep -Ec '\.ps1:[0-9]+:[0-9]+: \[' 2>/dev/null || echo "0")

if [ "$_diag_exit" -ne 0 ] && [ "$_diag_count" -gt 0 ]; then
  assert_pass "Injection preserves diagnostics: $_diag_count total, exit $_diag_exit"
else
  assert_fail "Injection preserves diagnostics" "Expected exit != 0 with diag count > 0, got exit=$_diag_exit, diag=$_diag_count"
fi

# ---------------------------------------------------------------------------
# Test 6: Standalone function call with single Windows file (cross-host).
# ---------------------------------------------------------------------------
echo "--- Test 6: Standalone function with Windows file ---"

_WIN_FILE="src/hosts/Windows/apply.ps1"
if [ -f "$_WIN_FILE" ]; then
  set +e
  # shellcheck disable=SC2016 # reason: PowerShell syntax ($rp, $env, $result) inside single-quoted -Command, not shell variables
  _single_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" NUCLEUS_TEST_WIN_FILE="$_WIN_FILE" pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $rp = $env:NUCLEUS_TEST_ROOT
    $wf = $env:NUCLEUS_TEST_WIN_FILE
    $ErrorActionPreference = "Stop"
    Set-StrictMode -Version Latest
    Import-Module PSScriptAnalyzer
    . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
    $result = Initialize-PSScriptAnalyzerCache -Files @("$rp/$wf") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1"
    Write-Output "INJECTED=$($result.InjectedNameCount)"
  ' 2>&1)
  _single_exit=$?
  set -e

  if [ "$_single_exit" -eq 0 ]; then
    assert_pass "Standalone Windows file: function executes without error"
  else
    assert_fail "Standalone Windows file: function executes without error" "Exit code: $_single_exit"
  fi

  if echo "$_single_out" | grep -q '^INJECTED=[1-9]'; then
    assert_pass "Standalone Windows file: injected at least one command name"
  else
    assert_fail "Standalone Windows file: injected at least one command name" "Output: $_single_out"
  fi
else
  echo -e "\033[1;33m⊘\033[0m Standalone Windows file: skipped ($_WIN_FILE not found)"
fi

# ---------------------------------------------------------------------------
# Test 7: Empty workaround disables injection (InjectedNameCount=0).
# ---------------------------------------------------------------------------
echo "--- Test 7: Empty workaround disables injection ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax inside single-quoted -Command
_empty_wa_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = $env:NUCLEUS_TEST_ROOT
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  Import-Module PSScriptAnalyzer
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  $result = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -Workaround @()
  Write-Output "INJECTED=$($result.InjectedNameCount)"
' 2>&1)
_empty_wa_exit=$?
set -e

if [ "$_empty_wa_exit" -eq 0 ]; then
  assert_pass "Empty workaround: function executes without error"
else
  assert_fail "Empty workaround: function executes without error" "Exit code: $_empty_wa_exit, Output: $_empty_wa_out"
fi

if echo "$_empty_wa_out" | grep -q '^INJECTED=0$'; then
  assert_pass "Empty workaround: injected 0 command names (injection skipped)"
else
  assert_fail "Empty workaround: injected 0 command names" "Expected INJECTED=0, got: $_empty_wa_out"
fi

# ---------------------------------------------------------------------------
# Test 8: \$RuleWorkaroundMap contains expected entry.
# ---------------------------------------------------------------------------
echo "--- Test 8: \$RuleWorkaroundMap ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax inside single-quoted -Command
_map_out=$(pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = "'"$REPO_ROOT"'"
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  $entry = $RuleWorkaroundMap["PSAvoidUsingCmdletAliases"]
  $count = $RuleWorkaroundMap.Count
  Write-Output "MAP_ENTRY=$entry"
  Write-Output "MAP_COUNT=$count"
' 2>&1)
_map_exit=$?
set -e

if [ "$_map_exit" -eq 0 ]; then
  assert_pass "RuleWorkaroundMap: dot-source publishes map without error"
else
  assert_fail "RuleWorkaroundMap: dot-source publishes map" "Exit code: $_map_exit, Output: $_map_out"
fi

if echo "$_map_out" | grep -q '^MAP_ENTRY=CachePrePopulation$'; then
  assert_pass "RuleWorkaroundMap: PSAvoidUsingCmdletAliases maps to CachePrePopulation"
else
  assert_fail "RuleWorkaroundMap: PSAvoidUsingCmdletAliases mapping" "Expected MAP_ENTRY=CachePrePopulation, got: $_map_out"
fi

if echo "$_map_out" | grep -q '^MAP_COUNT=[1-9]'; then
  assert_pass "RuleWorkaroundMap: has at least 1 entry"
else
  assert_fail "RuleWorkaroundMap: has entries" "Expected MAP_COUNT > 0, got: $_map_out"
fi

# ---------------------------------------------------------------------------
# Test 9: InjectRealOnly workaround with RealCommandMap injects real objects.
#         Only names present in RealCommandMap are injected; unmatched skipped.
# ---------------------------------------------------------------------------
echo "--- Test 9: InjectRealOnly with RealCommandMap ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($rp, $env, $result) inside single-quoted -Command, not shell variables
_hybrid_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = $env:NUCLEUS_TEST_ROOT
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  Import-Module PSScriptAnalyzer
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  $realMap = @{ "Write-Output" = (Get-Command Write-Output | ForEach-Object { $_.PSObject.BaseObject }) }
  $result = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -Workaround @("InjectRealOnly") -RealCommandMap $realMap
  Write-Output "INJECTED=$($result.InjectedNameCount)"
' 2>&1)
_hybrid_exit=$?
set -e

if [ "$_hybrid_exit" -eq 0 ]; then
  assert_pass "InjectRealOnly: executes without error"
else
  assert_fail "InjectRealOnly: executes without error" "Exit code: $_hybrid_exit, Output: $_hybrid_out"
fi

if echo "$_hybrid_out" | grep -q '^INJECTED=[1-9][0-9]*$'; then
  assert_pass "InjectRealOnly: injected at least 1 real command name"
else
  assert_fail "InjectRealOnly: injected at least 1 real command name" "Expected INJECTED=N with N>0, got: $_hybrid_out"
fi

# ---------------------------------------------------------------------------
# Test 10: TryAdd idempotence — real objects survive subsequent dummy injection.
#          InjectRealOnly injects real Write-Output, then CachePrePopulation
#          tries to inject dummies for everything. TryAdd skips existing keys.
# ---------------------------------------------------------------------------
echo "--- Test 10: TryAdd idempotence (real survives dummies) ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($rp, $env, $result) inside single-quoted -Command, not shell variables
_tryadd_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = $env:NUCLEUS_TEST_ROOT
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  Import-Module PSScriptAnalyzer
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  # Phase B: inject real objects only
  $realMap = @{ "Write-Output" = (Get-Command Write-Output | ForEach-Object { $_.PSObject.BaseObject }) }
  $resultB = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -Workaround @("InjectRealOnly") -RealCommandMap $realMap
  # Phase C: inject dummies for all names (TryAdd skips existing Write-Output)
  $resultC = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -Workaround @("CachePrePopulation")
  Write-Output "B=$($resultB.InjectedNameCount) C=$($resultC.InjectedNameCount)"
' 2>&1)
_tryadd_exit=$?
set -e

if [ "$_tryadd_exit" -eq 0 ]; then
  assert_pass "TryAdd idempotence: two-phase injection executes without error"
else
  assert_fail "TryAdd idempotence: two-phase injection executes without error" "Exit code: $_tryadd_exit, Output: $_tryadd_out"
fi

if echo "$_tryadd_out" | grep -qE '^B=[1-9][0-9]* C=[1-9][0-9]*$'; then
  assert_pass "TryAdd idempotence: both phases injected names (B > 0, C > 0)"
else
  assert_fail "TryAdd idempotence: both phases injected names" "Expected B=N C=M with N,M>0, got: $_tryadd_out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Tests passed: $TESTS_PASSED, failed: $TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
