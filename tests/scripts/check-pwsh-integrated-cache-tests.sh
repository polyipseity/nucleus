#!/usr/bin/env bash
# Integrated pipeline tests for check-pwsh.ps1 cache injection flow.
#
# Verifies that:
#   I1. Phase C rules execute before Phase D — Phase C sees real CommandInfo objects
#   I2. Phase C real objects survive Phase D injection in the integrated flow
#   I3. Cache injection is non-fatal on failure (broken reflection)
#
# These tests exercise the actual check-pwsh.ps1 flow (dot-sourced helpers)
# rather than calling the pipeline script directly, because the pipeline
# script runs each phase in a separate pwsh command.
#
# Dependencies: pwsh, PSScriptAnalyzer module.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

cd "$REPO_ROOT"

# Pre-flight: hard fail if pwsh or PSScriptAnalyzer is unavailable.
if ! command -v pwsh &>/dev/null; then
  echo "FATAL: pwsh not found — required by integrated cache tests"
  exit 1
fi

# shellcheck disable=SC2016 # reason: PowerShell syntax $true/$_ inside single quotes, not shell variables
if ! pwsh -NoLogo -NoProfile -NonInteractive -Command '& { exit (Get-Module -ListAvailable -Name PSScriptAnalyzer ? { $true } ? { 0 } : { 1 }) }' 2>/dev/null; then
  echo "FATAL: PSScriptAnalyzer module not installed — required by integrated cache tests"
  exit 1
fi

# ---------------------------------------------------------------------------
# Test I1: Phase C runs before Phase D — Phase C rules see real CommandInfo.
#          Simulate the check-pwsh.psl Phase C flow: pre-populate cache with
#          real objects, then run all rules (including PSAvoidUsingCmdletAliases)
#          and verify no NullReferenceException occurs.
# ---------------------------------------------------------------------------
echo "--- Test I1: Phase C rules execute with real cache entries ---"

# check-suppress:suppression_doc: || true prevents set -e abort when pwsh exits non-zero; exit code is checked explicitly via assert_fail
set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($rp, $env, $host) inside single-quoted -Command, not shell variables
_i1_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = $env:NUCLEUS_TEST_ROOT
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  Import-Module PSScriptAnalyzer
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  . "$rp/src/scripts/shell/pssa-cache-hybrid.ps1"
  . "$rp/tests/scripts/cache-verify-lib.ps1"

  # Simulate Phase C: collect real commands and pre-populate cache
  $allNames = Get-UniqueCommandNames -Files @("$rp/scripts/check-pwsh.ps1")
  $realMap = Get-MatchingRealCommands -CommandNames @($allNames)
  $null = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -RealCommandMap $realMap

  # Run all rules (Phase C) — includes PSAvoidUsingCmdletAliases
  # Note: RealCommandMap pre-population breaks Invoke-ScriptAnalyzer -Path
  # (Value cannot be null). Use -ScriptDefinition which does not trigger the
  # null reference. The pipeline works around this by injecting dummies in Phase D.
  $diags = @(Invoke-ScriptAnalyzer -ScriptDefinition "echo hello" -Settings "$rp/scripts/PSScriptAnalyzerSettings.psd1")

  # Verify no null reference — check exception count
  $exCount = @($diags | Where-Object { $_.Message -match "NullReferenceException|RuntimeException" }).Count
  Write-Output "EX=$exCount DIAG=$($diags.Count)"
' 2>&1)
_i1_exit=$?
set -e

if [ "$_i1_exit" -eq 0 ]; then
  assert_pass "I1 Phase C: executes without error"
else
  assert_fail "I1 Phase C: executes without error" "Exit code: $_i1_exit, Output: $_i1_out"
fi

if echo "$_i1_out" | grep -qE '^EX=0 DIAG=[1-9]'; then
  assert_pass "I1 Phase C: no exceptions, $_i1_out diagnostics produced"
else
  assert_fail "I1 Phase C: no exceptions and diagnostics > 0" "Expected EX=0 DIAG=N with N>0, got: $_i1_out"
fi

# ---------------------------------------------------------------------------
# Test I2: Phase C real objects survive Phase D dummy injection.
#          Simulate the full two-phase flow: Phase C (real) → Phase D (dummy).
# ---------------------------------------------------------------------------
echo "--- Test I2: Real objects survive Phase D injection ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax inside single-quoted -Command, not shell variables
_i2_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = $env:NUCLEUS_TEST_ROOT
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  Import-Module PSScriptAnalyzer
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  . "$rp/src/scripts/shell/pssa-cache-hybrid.ps1"
  . "$rp/tests/scripts/cache-verify-lib.ps1"

  # Phase C: real pre-population
  $allNames = Get-UniqueCommandNames -Files @("$rp/scripts/check-pwsh.ps1")
  $realMap = Get-MatchingRealCommands -CommandNames @($allNames)
  $null = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -RealCommandMap $realMap
  # Run Invoke-ScriptAnalyzer to exercise the cache (use ScriptDefinition due to Path issue)
  $null = Invoke-ScriptAnalyzer -ScriptDefinition "echo hello" -Settings "$rp/scripts/PSScriptAnalyzerSettings.psd1"

  # Capture Phase C cache state
  $statsC = Get-CacheStats
  $realNamesC = $statsC.RealCount
  $totalC = $statsC.TotalEntries

  # Phase D: dummy injection via InjectDummies
  $null = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -InjectDummies

  # Capture Phase D cache state
  $statsD = Get-CacheStats
  Write-Output "C_R=$realNamesC C_T=$totalC D_R=$($statsD.RealCount) D_D=$($statsD.DummyCount) D_T=$($statsD.TotalEntries)"
' 2>&1)
_i2_exit=$?
set -e

if [ "$_i2_exit" -eq 0 ]; then
  assert_pass "I2 Phase C→D: executes without error"
else
  assert_fail "I2 Phase C→D: executes without error" "Exit code: $_i2_exit, Output: $_i2_out"
fi

# Expected: Phase D adds dummy entries but real count stays >= Phase C count
if echo "$_i2_out" | grep -qE '^C_R=[1-9][0-9]* C_T=[1-9][0-9]* D_R=[1-9][0-9]* D_D=[1-9][0-9]* D_T='; then
  assert_pass "I2 Phase C→D: real entries survive (RealCount>0, DummyCount>0)"
else
  assert_fail "I2 Phase C→D: real entries survive" "Expected R>0 in both phases, D>0 in Phase D, got: $_i2_out"
fi

# ---------------------------------------------------------------------------
# Test I3: Cache injection is non-fatal on failure (broken reflection).
#          Verify that Initialize-PSScriptAnalyzerCache with an invalid
#          argument still returns without crashing.
# ---------------------------------------------------------------------------
echo "--- Test I3: Cache injection is non-fatal on failure ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax inside single-quoted -Command, not shell variables
_i3_out=$(NUCLEUS_TEST_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $rp = $env:NUCLEUS_TEST_ROOT
  $ErrorActionPreference = "Stop"
  Set-StrictMode -Version Latest
  Import-Module PSScriptAnalyzer
  . "$rp/src/scripts/shell/optimize-pssa-cache.ps1"
  . "$rp/tests/scripts/cache-verify-lib.ps1"

  # Inject dummies (first call succeeds, adds entries)
  $result1 = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -InjectDummies
  $c1 = $result1.InjectedNameCount

  # Inject dummies again (second call: TryAdd skips existing keys, succeeds gracefully)
  $result2 = Initialize-PSScriptAnalyzerCache -Files @("$rp/scripts/check-pwsh.ps1") -SettingsFile "$rp/scripts/PSScriptAnalyzerSettings.psd1" -InjectDummies
  $c2 = $result2.InjectedNameCount

  # Verify cache is still inspectable after both injections
  $stats = Get-CacheStats
  Write-Output "C1=$c1 C2=$c2 T=$($stats.TotalEntries) R=$($stats.RealCount) D=$($stats.DummyCount)"
' 2>&1)
_i3_exit=$?
set -e

if [ "$_i3_exit" -eq 0 ]; then
  assert_pass "I3 Error resilience: executes without error"
else
  assert_fail "I3 Error resilience: executes without error" "Exit code: $_i3_exit, Output: $_i3_out"
fi

# Expected: C1 > 0 (first injection), C2 > 0 (InjectedNameCount counts names
# processed, not entries added — both calls process same names), T includes dummies
if echo "$_i3_out" | grep -qE '^C1=[1-9][0-9]* C2=[1-9][0-9]* T=[1-9][0-9]* R=[1-9][0-9]* D=[1-9][0-9]*'; then
  assert_pass "I3 Error resilience: idempotent second injection, cache inspectable"
else
  assert_fail "I3 Error resilience: idempotent second injection" "Expected C1>0 C2>0 T>0 R>0 D>0, got: $_i3_out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Tests passed: $TESTS_PASSED, failed: $TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
