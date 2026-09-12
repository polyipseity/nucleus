#!/usr/bin/env bash
# shellcheck shell=bash
# Test: commit-staged.prompt.md body must match between repo and user overlay.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Strip YAML frontmatter (everything between first pair of --- markers).
_strip_frontmatter() {
  awk 'BEGIN{fm=0} /^---$/ {fm++; if (fm == 1) next; if (fm == 2) {fm = 3; next}} fm == 1 || fm == 2 {next} {print}' "$1"
}

test_commit_staged_body_match() {
  local _repo_file="$REPO_ROOT/.agents/prompts/commit-staged.prompt.md"
  local _user_file="$REPO_ROOT/src/users/default/agents/prompts/commit-staged.prompt.md"
  local _repo_body _user_body

  if [ ! -f "$_repo_file" ]; then
    echo "FAIL: repo commit-staged.prompt.md not found at $_repo_file"
    return 1
  fi
  if [ ! -f "$_user_file" ]; then
    echo "FAIL: user commit-staged.prompt.md not found at $_user_file"
    return 1
  fi

  _repo_body=$(_strip_frontmatter "$_repo_file")
  _user_body=$(_strip_frontmatter "$_user_file")

  if [ "$_repo_body" != "$_user_body" ]; then
    echo "FAIL: commit-staged.prompt.md body mismatch between repo and user overlay"
    return 1
  fi
  return 0
}

failures=0
for test_func in test_commit_staged_body_match; do
  if ! "$test_func"; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
