#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
# Tests for src/scripts/configs/merge-libreoffice-xcu.py
#
# Verifies the Python merge script correctly:
#   • Creates a new XCU file from scratch
#   • Updates existing values
#   • Inserts new props into existing items
#   • Creates new items
#
# Run with: bash tests/scripts/merge-libreoffice-xcu-tests.sh

. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MERGE_SCRIPT="$REPO_ROOT/src/scripts/configs/merge-libreoffice-xcu.py"

# Detect python3: prefer python3, fall back to python.
PYTHON3=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON3="$candidate"
    break
  fi
done
if [ -z "$PYTHON3" ]; then
  echo "SKIP: python3 not found" >&2
  exit 0
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Test: create new file ────────────────────────────────────────────
test_create_new_file() {
  local xcu="$TMPDIR_TEST/create.xcu"
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.UserProfile/Data|givenname|Alice" \
    "/org.openoffice.UserProfile/Data|sn|Smith" 2>&1

  if [ ! -f "$xcu" ]; then
    assert_fail "create_new_file: XCU file created" "file missing"
    return
  fi

  if grep -q 'givenname' "$xcu" && grep -q 'Alice' "$xcu"; then
    assert_pass "create_new_file: givenname entry present"
  else
    assert_fail "create_new_file: givenname entry present" "entry not found in XCU"
  fi

  if grep -q 'sn' "$xcu" && grep -q 'Smith' "$xcu"; then
    assert_pass "create_new_file: sn entry present"
  else
    assert_fail "create_new_file: sn entry present" "entry not found in XCU"
  fi
}

# ── Test: update existing value ──────────────────────────────────────
test_update_existing_value() {
  local xcu="$TMPDIR_TEST/update.xcu"
  # Create initial file.
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.Office.Common/Security/Scripting|RemovePersonalInfoOnSave|false" 2>&1
  # Update the value.
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.Office.Common/Security/Scripting|RemovePersonalInfoOnSave|true" 2>&1

  local count
  count=$(grep -c 'RemovePersonalInfoOnSave' "$xcu" 2>/dev/null || echo 0)
  if [ "$count" -eq 1 ]; then
    assert_pass "update_existing_value: no duplicate entry"
  else
    assert_fail "update_existing_value: no duplicate entry" "found $count occurrences"
  fi

  if grep -q 'true' "$xcu"; then
    assert_pass "update_existing_value: value updated to true"
  else
    assert_fail "update_existing_value: value updated to true" "value not found"
  fi
}

# ── Test: insert prop into existing item ──────────────────────────────
test_insert_prop_into_existing_item() {
  local xcu="$TMPDIR_TEST/insert-prop.xcu"
  # Create initial file with one prop under an item.
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.UserProfile/Data|givenname|Alice" 2>&1
  # Insert a second prop into the same item.
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.UserProfile/Data|sn|Smith" 2>&1

  if grep -q 'givenname' "$xcu" && grep -q 'sn' "$xcu"; then
    assert_pass "insert_prop_into_existing_item: both props present"
  else
    assert_fail "insert_prop_into_existing_item: both props present" "missing prop"
  fi
}

# ── Test: create new item ────────────────────────────────────────────
test_create_new_item() {
  local xcu="$TMPDIR_TEST/new-item.xcu"
  # Create initial file with one item.
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.UserProfile/Data|givenname|Alice" 2>&1
  # Add a different item.
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.Office.Common/Security/Scripting|RemovePersonalInfoOnSave|true" 2>&1

  local item_count
  item_count=$(grep -o 'oor:path=' "$xcu" | wc -l)
  if [ "$item_count" -eq 2 ]; then
    assert_pass "create_new_item: two distinct items present"
  else
    assert_fail "create_new_item: two distinct items present" "found $item_count items"
  fi
}

# ── Test: empty string value ─────────────────────────────────────────
test_empty_string_value() {
  local xcu="$TMPDIR_TEST/empty-value.xcu"
  "$PYTHON3" "$MERGE_SCRIPT" "$xcu" \
    "/org.openoffice.UserProfile/Data|mail|" 2>&1

  if grep -q 'mail' "$xcu" && grep -qE '<oor:value\s*/>' "$xcu"; then
    assert_pass "empty_string_value: empty value element created"
  else
    assert_fail "empty_string_value: empty value element created" "empty value not found"
  fi
}

# ── Run all tests ────────────────────────────────────────────────────
section "merge-libreoffice-xcu" "Python XCU merge script tests"

test_create_new_file
test_update_existing_value
test_insert_prop_into_existing_item
test_create_new_item
test_empty_string_value

# ── Summary ──────────────────────────────────────────────────────────
section "Summary" ""
if [ "$TESTS_FAILED" -gt 0 ]; then
  printf '%d failed, %d passed\n' "$TESTS_FAILED" "$TESTS_PASSED"
  exit 1
fi

printf 'all %d tests passed.\n' "$TESTS_PASSED"
exit 0
