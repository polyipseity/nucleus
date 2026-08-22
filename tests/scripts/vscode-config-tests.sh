#!/usr/bin/env bash
# Shell tests for src/scripts/editors/symlink-vscode-config.sh: the
# chatLanguageModels.json merge-copy behavior — corrupt-file recovery,
# name-keyed merge that preserves VS Code-added entries, and the index-0
# repo-entry refresh (regression guard for the jq merge warning).
#
# Run with: bash tests/scripts/vscode-config-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=./user-registry-fixture.sh
. "$SCRIPT_DIR/user-registry-fixture.sh"

VSCODE_CONFIG="$REAL_REPO_ROOT/src/scripts/editors/symlink-vscode-config.sh"
readonly VSCODE_CONFIG
VSCODE_CHAT_LM_REPO="$REAL_REPO_ROOT/src/users/default/vscode/chatLanguageModels.MacBook.json"
readonly VSCODE_CHAT_LM_REPO
JQ_BIN="$(command -v jq)"
readonly JQ_BIN

# The script sets immutable flags (uchg on macOS, chattr +i on Linux) on the
# symlinks it creates, so plain rm -rf fails on macOS. Clear the flags first.
cleanup_tree() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  if command -v chflags >/dev/null 2>&1; then
    find "$dir" -type l -exec chflags -h nouchg {} + 2>/dev/null || true
  fi
  if command -v chattr >/dev/null 2>&1; then
    find "$dir" -type l -exec chattr -h -i {} + 2>/dev/null || true
  fi
  rm -rf "$dir"
}

# Run the VS Code config convergence against an isolated base dir. The script
# resolves repo-source files from REAL_REPO_ROOT and writes into the per-channel
# User data dirs under $1.
run_vscode_config() {
  local base="$1"
  HOME="$base" "$VSCODE_CONFIG" \
    "$REAL_REPO_ROOT" \
    "default" \
    "$base/stable" \
    "$base/insiders" \
    "keybindings.MacBook.json" \
    "chatLanguageModels.MacBook.json" \
    "$JQ_BIN"
}

assert_valid_json() {
  local test_name="$1" path="$2"
  if [ ! -s "$path" ] || ! "$JQ_BIN" -e . "$path" >/dev/null 2>&1; then
    assert_fail "$test_name" "not valid/non-empty JSON at $path"
    return 1
  fi
  assert_pass "$test_name"
}

assert_matches_repo_source() {
  local test_name="$1" path="$2"
  local actual repo
  actual="$("$JQ_BIN" -c . "$path")"
  repo="$("$JQ_BIN" -c . "$VSCODE_CHAT_LM_REPO")"
  if [ "$actual" != "$repo" ]; then
    assert_fail "$test_name" "content differs from repo source"
    return 1
  fi
  assert_pass "$test_name"
}

test_corrupt_replaced() {
  local base
  base="$(mktemp -d)"
  trap 'cleanup_tree "${base:-}"' RETURN
  mkdir -p "$base/stable"

  # A corrupt existing file cannot be merged; the script must replace it from
  # the repo source rather than keeping the corrupt content (the old warning).
  printf '{ this is not valid json ' >"$base/stable/chatLanguageModels.json"
  run_vscode_config "$base"

  assert_valid_json "corrupt: replaced with valid JSON" "$base/stable/chatLanguageModels.json" || return 1
  assert_matches_repo_source "corrupt: replaced with repo source" "$base/stable/chatLanguageModels.json"
}

test_absent_copied() {
  local base
  base="$(mktemp -d)"
  trap 'cleanup_tree "${base:-}"' RETURN
  mkdir -p "$base/stable"

  # No existing file -> copy the repo source verbatim.
  run_vscode_config "$base"

  assert_valid_json "absent: repo source copied" "$base/stable/chatLanguageModels.json" || return 1
  assert_matches_repo_source "absent: repo source copied" "$base/stable/chatLanguageModels.json"
}

test_merge_preserves_user_entries() {
  local base
  base="$(mktemp -d)"
  trap 'cleanup_tree "${base:-}"' RETURN
  mkdir -p "$base/stable"

  # Existing file: a stale repo entry at index 0 (LiteLLM) plus a user-added
  # entry (OllamaLocal) that the repo does not manage.
  cat >"$base/stable/chatLanguageModels.json" <<'JSON'
[
  { "name": "LiteLLM", "stale": true },
  { "name": "OllamaLocal", "baseUrl": "http://localhost:11434" }
]
JSON
  run_vscode_config "$base"

  # User-added entry must survive the merge.
  if ! "$JQ_BIN" -e 'any(.[]; .name == "OllamaLocal")' "$base/stable/chatLanguageModels.json" >/dev/null 2>&1; then
    assert_fail "merge: user-added entry preserved" "OllamaLocal missing after merge"
    return 1
  fi
  # Repo entry at index 0 must be refreshed from the repo source (the old
  # `if $idx then` bug dropped index-0 updates).
  if ! "$JQ_BIN" -e 'any(.[]; .name == "LiteLLM" and (.stale // false) == false)' "$base/stable/chatLanguageModels.json" >/dev/null 2>&1; then
    assert_fail "merge: index-0 repo entry refreshed" "LiteLLM not refreshed from repo"
    return 1
  fi
  assert_pass "merge: user-added entry preserved and index-0 repo entry refreshed"
}

main() {
  test_corrupt_replaced
  test_absent_copied
  test_merge_preserves_user_entries

  echo ""
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
