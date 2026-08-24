#!/usr/bin/env bash
# Smoke tests for check-pwsh.ps1 CLI (-SkipStep, -Paths).
# Uses -SkipStep PSSA for syntax-only probes; check step 2 runs syntax on pre-commit.
# PSScriptAnalyzer runs in test step 2 (-SkipStep Syntax).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

cd "$REPO_ROOT"

_ps_script="src/scripts/checks/check-pwsh.ps1"

# 1. Syntax validation passes on a known-good file.
if pwsh -NoLogo -NoProfile -NonInteractive -File "$_ps_script" -SkipStep PSSA -Paths "$_ps_script" >/dev/null 2>&1; then
  assert_pass "check-pwsh: syntax validation passes on known-good file"
else
  assert_fail "check-pwsh: syntax validation on known-good file" "exit code $?"
fi

# 2. Syntax validation handles nonexistent files gracefully (skips them).
if pwsh -NoLogo -NoProfile -NonInteractive -File "$_ps_script" -SkipStep PSSA -Paths /dev/null/nonexistent.ps1 >/dev/null 2>&1; then
  assert_pass "check-pwsh: nonexistent file handled gracefully"
else
  assert_fail "check-pwsh: nonexistent file" "exit code $?"
fi

# 3. Unknown -SkipStep names produce an error.
if pwsh -NoLogo -NoProfile -NonInteractive -File "$_ps_script" -SkipStep UnknownName -Paths "$_ps_script" >/dev/null 2>&1; then
  assert_fail "check-pwsh: unknown -SkipStep name should fail" "expected non-zero exit"
else
  assert_pass "check-pwsh: unknown -SkipStep name correctly rejected"
fi

# Summary
echo ""
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "check-pwsh smoke tests: $TESTS_FAILED failed, $TESTS_PASSED passed"
  exit 1
else
  echo "check-pwsh smoke tests: all $TESTS_PASSED passed"
fi
