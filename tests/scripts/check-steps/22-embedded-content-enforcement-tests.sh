#!/usr/bin/env bash
# Test: step 22 embedded-content enforcement must flag large heredocs (embedded-content policy)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/22-embedded-content-enforcement.sh"
AWK_FILE="$REPO_ROOT/src/scripts/checks/check-steps/22-embedded-content-enforcement.awk"

test_step22_has_heredoc_detector() {
  # Matches the awk opener regex /<<-?[ \t]*["\047\\]?[A-Za-z_]/
  if grep -q '<<-?' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 22 should detect heredoc openers"
  return 1
}

test_step22_has_30_line_threshold() {
  # Matches: if (body > 30) print ...
  if grep -q 'body > 30' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 22 should flag heredocs with more than 30 content lines"
  return 1
}

test_step22_uses_awk_file() {
  # The detector must be extracted to a sibling .awk file (shellcheck policy).
  if grep -q 'awk -f' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 22 should invoke its detector via awk -f"
  return 1
}

test_step22_has_category_c_ref() {
  if grep -q 'allow-and-deny-lists.instructions.md#C5' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 22 should register its self-exclusion in allow-and-deny-lists Category C"
  return 1
}

test_step22_has_self_exclusion() {
  # Matches: _s22_self_sh="$(basename "${BASH_SOURCE[0]}")"
  if grep -q 'basename.*BASH_SOURCE' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 22 should exclude its own source file"
  return 1
}

test_step22_uses_gitignore_filter() {
  if grep -q 'filter_gitignored' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 22 should apply the gitignore filter to its file list"
  return 1
}

if [ "$#" -eq 0 ] || [ "$1" = "test_step22_has_heredoc_detector" ]; then
  test_step22_has_heredoc_detector || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step22_has_30_line_threshold" ]; then
  test_step22_has_30_line_threshold || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step22_uses_awk_file" ]; then
  test_step22_uses_awk_file || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step22_has_category_c_ref" ]; then
  test_step22_has_category_c_ref || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step22_has_self_exclusion" ]; then
  test_step22_has_self_exclusion || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step22_uses_gitignore_filter" ]; then
  test_step22_uses_gitignore_filter || exit 1
fi
