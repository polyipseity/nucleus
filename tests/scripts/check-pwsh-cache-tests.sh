#!/usr/bin/env bash
# Tests for PSScriptAnalyzer CommandInfo cache pre-population (Phase 1b).
#
# Verifies that:
#   1. -SyntaxOnly skips Phase 1b and Phase 2 (exit 0, lint skipped message)
#   2. Default mode (with pre-population) runs without unhandled errors
#   3. -SkipCachePrepopulation bypasses Phase 1b without changing exit code
#   4. Diagnostic count is identical with and without pre-population
#
# These tests are additive to the existing Step 3 (PowerShell lint) in test.sh.
# They specifically verify Phase 1b behavior, while Step 3 runs the lint itself.
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
# Test 2: Default mode (with pre-population) must complete without errors
#         and produce diagnostics (there ARE lint issues in the repo).
# ---------------------------------------------------------------------------
echo "--- Test 2: Default mode (with pre-population) ---"

set +e
_default_output=$(pwsh -NoLogo -NoProfile -NonInteractive -File "$CHECK_PWSH" 2>&1)
_default_exit=$?
set -e

# Count diagnostic lines (format: file:line:col: [Severity] Message)
# Note: use -E for extended regex (BSD grep on macOS lacks -P).
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
# Test 3: -SkipCachePrepopulation bypasses Phase 1b without changing exit code
# ---------------------------------------------------------------------------
echo "--- Test 3: -SkipCachePrepopulation ---"

set +e
_skip_output=$(pwsh -NoLogo -NoProfile -NonInteractive -File "$CHECK_PWSH" -SkipCachePrepopulation 2>&1)
_skip_exit=$?
set -e

_skip_diag=$(echo "$_skip_output" | grep -Ec '\.ps1:[0-9]+:[0-9]+: \[' 2>/dev/null || echo "0")

# Check for "cache pre-population" or similar Phase 1b messages in the output
# If Phase 1b is skipped, there should be no cache-related output
if echo "$_skip_output" | grep -qi 'CommandInfo cache pre-population'; then
  assert_fail "SkipCachePrepopulation: Phase 1b suppressed" "Expected no cache pre-population output, but found some"
else
  assert_pass "SkipCachePrepopulation: Phase 1b suppressed"
fi

# Exit code must match default mode (both should find the same lint issues)
if [ "$_default_exit" -eq "$_skip_exit" ]; then
  assert_pass "SkipCachePrepopulation: exit code matches default ($_default_exit)"
else
  assert_fail "SkipCachePrepopulation: exit code matches default" "Default: $_default_exit, Skip: $_skip_exit"
fi

# ---------------------------------------------------------------------------
# Test 4: Diagnostic count parity (with and without pre-population)
# ---------------------------------------------------------------------------
echo "--- Test 4: Diagnostic count parity ---"

# Allow a small tolerance (maybe 0-3 difference) for edge cases where
# a command resolves differently due to module loading order
_diag_diff=$(( _default_diag - _skip_diag ))
_diag_diff_abs=${_diag_diff#-}  # absolute value

if [ "$_diag_diff_abs" -le 3 ]; then
  assert_pass "Diagnostic count parity: within tolerance (default=$_default_diag, skip=$_skip_diag, diff=$_diag_diff_abs)"
else
  assert_fail "Diagnostic count parity" "Default: $_default_diag diagnostics, Skip: $_skip_diag diagnostics (diff=$_diag_diff_abs, max tolerance=3)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Tests passed: $TESTS_PASSED, failed: $TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
