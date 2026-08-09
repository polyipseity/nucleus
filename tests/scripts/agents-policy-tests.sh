#!/usr/bin/env bash
# Tests for .agents drift guards in repository-policy check step 14.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

test_commit_staged_bodies_match() {
  local repo_prompt="${NUCLEUS_REPO_ROOT}/.agents/prompts/commit-staged.prompt.md"
  local user_prompt="${NUCLEUS_REPO_ROOT}/src/users/default/agents/prompts/commit-staged.prompt.md"
  local repo_body user_body
  repo_body=$(awk 'BEGIN{fm=0} /^---$/ {fm++; if (fm == 1) next; if (fm == 2) {fm = 3; next}} fm == 1 || fm == 2 {next} {print}' "$repo_prompt")
  user_body=$(awk 'BEGIN{fm=0} /^---$/ {fm++; if (fm == 1) next; if (fm == 2) {fm = 3; next}} fm == 1 || fm == 2 {next} {print}' "$user_prompt")
  if [[ "$repo_body" == "$user_body" ]]; then
    assert_pass "commit-staged prompt bodies match between repo and user overlay"
  else
    assert_fail "commit-staged prompt bodies match between repo and user overlay" "bodies differ"
  fi
}

test_instruction_frontmatter_present() {
  local missing=0
  local instr
  while IFS= read -r -d '' instr; do
    if ! awk 'NR==1 && $0=="---" {found=1; exit} END{exit !found}' "$instr"; then
      missing=$((missing + 1))
    fi
  done < <(find "${NUCLEUS_REPO_ROOT}/.agents/instructions" -type f -name '*.instructions.md' -print0)
  if [[ "$missing" -eq 0 ]]; then
    assert_pass "all .agents instructions have YAML frontmatter"
  else
    assert_fail "all .agents instructions have YAML frontmatter" "$missing file(s) missing frontmatter"
  fi
}

test_no_wide_applyto_globs() {
  local wide=0
  local instr
  while IFS= read -r -d '' instr; do
    if awk '/^---$/{n++; next} n==1 && /^applyTo:/{sub(/^applyTo: */, ""); gsub(/^"|"$/, ""); if ($0 == "**") exit 0; exit 1} END{exit 1}' "$instr"; then
      wide=$((wide + 1))
    fi
  done < <(find "${NUCLEUS_REPO_ROOT}/.agents/instructions" -type f -name '*.instructions.md' -print0)
  if [[ "$wide" -eq 0 ]]; then
    assert_pass "no instruction files use applyTo \"**\""
  else
    assert_fail "no instruction files use applyTo \"**\"" "$wide file(s) still use **"
  fi
}

test_no_stale_instruction_references() {
  local manifest="${NUCLEUS_REPO_ROOT}/.agents/deleted-instructions.json"
  local pattern hits
  pattern=$(jq -r '.stems | map(. + ".instructions.md") | join("|")' "$manifest")
  hits=$(grep -RIn -E "$pattern" \
    --exclude-dir='.git' \
    --exclude='14-repository-policy.sh' \
    --exclude='14-repository-policy.ps1' \
    --exclude='agents-policy-tests.sh' \
    --exclude='deleted-instructions.json' \
    "$NUCLEUS_REPO_ROOT" 2>/dev/null || true)
  if [[ -z "$hits" ]]; then
    assert_pass "no stale references to removed .agents instruction files"
  else
    assert_fail "no stale references to removed .agents instruction files" "$hits"
  fi
}

test_agents_md_instruction_links_resolve() {
  local missing
  missing=$(grep -oE '\.agents/instructions/[a-z0-9-]+\.instructions\.md' "${NUCLEUS_REPO_ROOT}/AGENTS.md" 2>/dev/null \
    | sort -u \
    | while IFS= read -r link; do
        [ -f "${NUCLEUS_REPO_ROOT}/${link}" ] || echo "$link"
      done || true)
  if [[ -z "$missing" ]]; then
    assert_pass "AGENTS.md instruction links resolve to existing files"
  else
    assert_fail "AGENTS.md instruction links resolve to existing files" "$missing"
  fi
}

main() {
  test_commit_staged_bodies_match
  test_instruction_frontmatter_present
  test_no_wide_applyto_globs
  test_no_stale_instruction_references
  test_agents_md_instruction_links_resolve

  echo ""
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
