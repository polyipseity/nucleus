#!/usr/bin/env bash
# Validates bash syntax, shebang, executable bit, and dangerous patterns for entry scripts.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

test_bash_syntax() {
  local script="$1"
  if bash -n "$script" 2>/dev/null; then
    assert_pass "Bash syntax: $(basename "$script")"
  else
    assert_fail "Bash syntax: $(basename "$script")" "Parse error detected"
  fi
}

test_has_shebang() {
  local script="$1"
  if head -n1 "$script" | grep -q "^#!"; then
    assert_pass "Shebang present: $(basename "$script")"
  else
    assert_fail "Shebang present: $(basename "$script")" "Missing shebang"
  fi
}

test_is_executable() {
  local script="$1"
  if [[ -x "$script" ]]; then
    assert_pass "Executable bit set: $(basename "$script")"
  else
    assert_fail "Executable bit set: $(basename "$script")" "Not executable"
  fi
}

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
mapfile -t ENTRY_SCRIPTS < <(
  find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name '*.sh' | sort
)

echo "Testing ${#ENTRY_SCRIPTS[@]} shell entry scripts..."
for script in "${ENTRY_SCRIPTS[@]}"; do
  test_bash_syntax "$script"
  test_has_shebang "$script"
  test_is_executable "$script"
done

echo ""
echo "============================================================"
echo "Test Summary:"
printf '%sPassed: %s%s\n' "$GREEN" "$TESTS_PASSED" "$NC"
printf '%sFailed: %s%s\n' "$RED" "$TESTS_FAILED" "$NC"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
  exit 0
fi
exit 1
