#!/usr/bin/env bash
# Tests for pssa-cache-hybrid.ps1 (Get-UniqueCommandNames, Get-MatchingRealCommands).
#
# Dependencies: pwsh, PSScriptAnalyzer module.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

cd "$REPO_ROOT"

HYBRID_FILE="src/scripts/shell/pssa-cache-hybrid.ps1"

# Pre-flight: skip all tests if pwsh is unavailable.
if ! command -v pwsh &>/dev/null; then
  echo -e "\033[1;33m⊘\033[0m All tests skipped: pwsh not found"
  exit 0
fi

# ---------------------------------------------------------------------------
# Test 1: Get-UniqueCommandNames returns non-empty set for a single file.
# ---------------------------------------------------------------------------
echo "--- Test 1: Get-UniqueCommandNames returns non-empty set ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($n, $_.Count) inside single-quoted -Command, not shell variables
_n1_out=$(pwsh -NoLogo -NoProfile -NonInteractive -Command '
  . "'"$REPO_ROOT/$HYBRID_FILE"'"
  $n = Get-UniqueCommandNames -Files "'"$REPO_ROOT/scripts/check-pwsh.ps1"'"
  Write-Output "COUNT=$($n.Count)"
' 2>&1)
_n1_exit=$?
set -e

if [ "$_n1_exit" -eq 0 ]; then
  assert_pass "Get-UniqueCommandNames: executes without error"
else
  assert_fail "Get-UniqueCommandNames: executes without error" "Exit code: $_n1_exit, Output: $_n1_out"
fi

if echo "$_n1_out" | grep -q '^COUNT=[1-9][0-9]*$'; then
  assert_pass "Get-UniqueCommandNames: returns at least 1 command name"
else
  assert_fail "Get-UniqueCommandNames: returns at least 1 command name" "Expected COUNT=N with N>0, got: $_n1_out"
fi

# ---------------------------------------------------------------------------
# Test 2: Get-UniqueCommandNames expands Get- prefixes for non-Get names.
# ---------------------------------------------------------------------------
echo "--- Test 2: Get-UniqueCommandNames expands Get- prefixes ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($n, -match, $hasGet) inside single-quoted -Command, not shell variables
_n2_out=$(pwsh -NoLogo -NoProfile -NonInteractive -Command '
  . "'"$REPO_ROOT/$HYBRID_FILE"'"
  $n = Get-UniqueCommandNames -Files "'"$REPO_ROOT/scripts/check-pwsh.ps1"'"
  $hasGet = [bool]($n -match "^Get-\w+")
  Write-Output "HAS_GET_PREFIX=$hasGet"
' 2>&1)
_n2_exit=$?
set -e

if [ "$_n2_exit" -eq 0 ]; then
  assert_pass "Get-UniqueCommandNames (Get- prefix): executes without error"
else
  assert_fail "Get-UniqueCommandNames (Get- prefix): executes without error" "Exit code: $_n2_exit, Output: $_n2_out"
fi

if echo "$_n2_out" | grep -q '^HAS_GET_PREFIX=True$'; then
  assert_pass "Get-UniqueCommandNames (Get- prefix): produces Get- prefixed entries"
else
  assert_fail "Get-UniqueCommandNames (Get- prefix): produces Get- prefixed entries" "Expected HAS_GET_PREFIX=True, got: $_n2_out"
fi

# ---------------------------------------------------------------------------
# Test 3: Get-MatchingRealCommands returns hashtable (count may be 0 in minimal CI).
# ---------------------------------------------------------------------------
echo "--- Test 3: Get-MatchingRealCommands returns hashtable ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($n, $m, $_.Count) inside single-quoted -Command, not shell variables
_n3_out=$(pwsh -NoLogo -NoProfile -NonInteractive -Command '
  . "'"$REPO_ROOT/$HYBRID_FILE"'"
  $n = Get-UniqueCommandNames -Files "'"$REPO_ROOT/scripts/check-pwsh.ps1"'"
  $m = Get-MatchingRealCommands -CommandNames @($n)
  Write-Output "COUNT=$($m.Count)"
' 2>&1)
_n3_exit=$?
set -e

if [ "$_n3_exit" -eq 0 ]; then
  assert_pass "Get-MatchingRealCommands: executes without error"
else
  assert_fail "Get-MatchingRealCommands: executes without error" "Exit code: $_n3_exit, Output: $_n3_out"
fi

if echo "$_n3_out" | grep -qE '^COUNT=[0-9]+$'; then
  assert_pass "Get-MatchingRealCommands: returns numeric count"
else
  assert_fail "Get-MatchingRealCommands: returns numeric count" "Expected COUNT=N, got: $_n3_out"
fi

# ---------------------------------------------------------------------------
# Test 4: Get-MatchingRealCommands returns unwrapped CommandInfo objects.
# ---------------------------------------------------------------------------
echo "--- Test 4: Get-MatchingRealCommands returns unwrapped CommandInfo ---"

set +e
# shellcheck disable=SC2016 # reason: PowerShell syntax ($m, $_.GetType) inside single-quoted -Command, not shell variables
_n4_out=$(pwsh -NoLogo -NoProfile -NonInteractive -Command '
  . "'"$REPO_ROOT/$HYBRID_FILE"'"
  $m = Get-MatchingRealCommands -CommandNames @("Write-Output")
  if ($m.ContainsKey("Write-Output")) {
    $t = $m["Write-Output"].GetType().Name
    Write-Output "TYPE=$t"
  } else {
    Write-Output "TYPE=NOT_FOUND"
  }
' 2>&1)
_n4_exit=$?
set -e

if [ "$_n4_exit" -eq 0 ]; then
  assert_pass "Get-MatchingRealCommands (unwrap): executes without error"
else
  assert_fail "Get-MatchingRealCommands (unwrap): executes without error" "Exit code: $_n4_exit, Output: $_n4_out"
fi

if echo "$_n4_out" | grep -qE '^TYPE=(CmdletInfo|FunctionInfo)$'; then
  assert_pass "Get-MatchingRealCommands (unwrap): returns CmdletInfo or FunctionInfo (not PSObject)"
else
  assert_fail "Get-MatchingRealCommands (unwrap): returns CmdletInfo or FunctionInfo" "Expected TYPE=CmdletInfo or FunctionInfo, got: $_n4_out"
fi

# ---------------------------------------------------------------------------
# Test 5: Dot-source does not throw under strict mode.
# ---------------------------------------------------------------------------
echo "--- Test 5: Dot-source does not throw ---"

set +e
_n5_out=$(pwsh -NoLogo -NoProfile -NonInteractive -Command '
  Set-StrictMode -Version Latest
  $ErrorActionPreference = "Stop"
  . "'"$REPO_ROOT/$HYBRID_FILE"'"
  exit 0
' 2>&1)
_n5_exit=$?
set -e

if [ "$_n5_exit" -eq 0 ]; then
  assert_pass "Dot-source: loads without error"
else
  assert_fail "Dot-source: loads without error" "Exit code: $_n5_exit, Output: $_n5_out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
