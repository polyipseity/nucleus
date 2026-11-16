#!/usr/bin/env bash
# Tests for src/scripts/lib/apply-history.sh (G3 Task 5).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state
ensure_safe_rm_env

# shellcheck source=../../src/scripts/lib/lib.sh
. "$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/apply-history.sh
. "$SCRIPT_DIR/../../src/scripts/lib/apply-history.sh"

require_command jq "apply-history uses jq for JSON"
require_command git "apply-history git field derivation uses git"

_write_limit_config() {
  local limit="$1"
  local cfgdir="$HOME/.local/state/nucleus"
  mkdir -p "$cfgdir"
  printf '{"applyHistoryLimit":%s}\n' "$limit" >"$cfgdir/config.json"
}

_t_non_git_record() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  _write_limit_config 256
  rm -f "$(apply_history_path)" 2>/dev/null || true
  apply_history_record "success" "" "$tmpdir" "TestHost" "testuser"
  local hist
  hist="$(apply_history_path)"
  if [ ! -f "$hist" ]; then
    assert_fail "non-git record creates history file" "missing $hist"
    rm -rf "$tmpdir"
    return
  fi
  local line
  line="$(tail -1 "$hist")"
  local ok=1
  if ! printf '%s' "$line" | jq -e '.version == 1' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.result == "success"' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.phase == null' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.host == "TestHost"' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.user == "testuser"' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e --arg rr "$tmpdir" '.repoRoot == $rr' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.commitHash == null and .branch == null and .detachedHead == null and .appliedCommitTag == null and .lastTagOnBranch == null and .hasUnstaged == null and .hasStaged == null and .hasUntracked == null and .isDirty == null' >/dev/null 2>&1; then
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    assert_pass "non-git record has correct shape and null git fields"
  else
    assert_fail "non-git record shape" "line=[$line]"
  fi
  rm -rf "$tmpdir"
}

_t_failure_phase() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  _write_limit_config 256
  rm -f "$(apply_history_path)" 2>/dev/null || true
  apply_history_record "failure" "rebuild" "$tmpdir" "TestHost" "testuser"
  local line
  line="$(tail -1 "$(apply_history_path)")"
  if printf '%s' "$line" | jq -e '.result == "failure" and .phase == "rebuild"' >/dev/null 2>&1; then
    assert_pass "failure record carries phase"
  else
    assert_fail "failure record phase" "line=[$line]"
  fi
  rm -rf "$tmpdir"
}

_t_limit_zero_disables_writes() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  _write_limit_config 0
  rm -f "$(apply_history_path)" 2>/dev/null || true
  apply_history_record "success" "" "$tmpdir" "H" "u"
  if [ ! -f "$(apply_history_path)" ]; then
    assert_pass "limit 0 disables writes (no file created)"
  else
    assert_fail "limit 0 disables writes" "file exists"
  fi
  rm -rf "$tmpdir"
}

_t_limit_positive_keeps_newest_n() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  _write_limit_config 2
  rm -f "$(apply_history_path)" 2>/dev/null || true
  apply_history_record "success" "" "$tmpdir" "H" "u1"
  sleep 0.01
  apply_history_record "success" "" "$tmpdir" "H" "u2"
  sleep 0.01
  apply_history_record "failure" "preflight" "$tmpdir" "H" "u3"
  local count
  count="$(wc -l <"$(apply_history_path)" | tr -d ' ')"
  if [ "$count" != "2" ]; then
    assert_fail "limit 2 keeps newest 2" "count=$count"
    rm -rf "$tmpdir"
    return
  fi
  local last_user
  last_user="$(tail -1 "$(apply_history_path)" | jq -r '.user')"
  if [ "$last_user" = "u3" ]; then
    assert_pass "limit 2 keeps newest 2 (newest is u3)"
  else
    assert_fail "limit 2 newest is u3" "last_user=$last_user"
  fi
  rm -rf "$tmpdir"
}

_t_limit_negative_unlimited() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  _write_limit_config -1
  rm -f "$(apply_history_path)" 2>/dev/null || true
  apply_history_record "success" "" "$tmpdir" "H" "u1"
  apply_history_record "success" "" "$tmpdir" "H" "u2"
  apply_history_record "success" "" "$tmpdir" "H" "u3"
  local count
  count="$(wc -l <"$(apply_history_path)" | tr -d ' ')"
  if [ "$count" = "3" ]; then
    assert_pass "limit -1 keeps all records (unlimited)"
  else
    assert_fail "limit -1 unlimited" "count=$count"
  fi
  rm -rf "$tmpdir"
}

_t_corrupt_line_reported() {
  local tmpdir hist
  tmpdir="$(mktemp -d)"
  hist="$(apply_history_path)"
  mkdir -p "$(dirname "$hist")"
  printf '{"version":1}\nnot-json\n' >"$hist"
  local out rc=0
  out="$(apply_history_read_entries_json 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "corrupt line 2"; then
    assert_pass "corrupt line reported naming line 2"
  else
    assert_fail "corrupt line reporting" "rc=$rc out=[$out]"
  fi
  rm -rf "$tmpdir"
}

_t_reader_json_newest_first_and_empty() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f "$(apply_history_path)" 2>/dev/null || true
  local j
  j="$(apply_history_read_entries_json)"
  if ! printf '%s' "$j" | jq -e '.version == 1 and (.entries | length == 0)' >/dev/null 2>&1; then
    assert_fail "empty history returns entries empty" "j=$j"
    rm -rf "$tmpdir"
    return
  fi
  _write_limit_config 256
  apply_history_record "success" "" "$tmpdir" "H" "first"
  sleep 0.02
  apply_history_record "failure" "post-apply" "$tmpdir" "H" "second"
  j="$(apply_history_read_entries_json)"
  local u0 u1
  u0="$(printf '%s' "$j" | jq -r '.entries[0].user')"
  u1="$(printf '%s' "$j" | jq -r '.entries[1].user')"
  if [ "$u0" = "second" ] && [ "$u1" = "first" ]; then
    assert_pass "entries JSON is newest first and empty case handled"
  else
    assert_fail "newest first" "u0=$u0 u1=$u1"
  fi
  rm -rf "$tmpdir"
}

_t_reader_human_latest() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f "$(apply_history_path)" 2>/dev/null || true
  local out
  out="$(apply_history_read_latest_human)"
  if printf '%s' "$out" | grep -q "No apply history yet."; then
    assert_pass "human latest says no history when empty"
  else
    assert_fail "human latest empty" "out=[$out]"
  fi
  rm -rf "$tmpdir"
}

_git() {
  git -c user.name='Test User' -c user.email='test@example.com' -c commit.gpgsign=false "$@"
}

_t_git_repo_derivation() {
  local repo
  repo="$(mktemp -d)"
  _write_limit_config 256
  rm -f "$(apply_history_path)" 2>/dev/null || true

  # init and clean commit
  _git -C "$repo" init -q
  printf 'a\n' >"$repo/file.txt"
  _git -C "$repo" add file.txt
  _git -C "$repo" commit -qm 'init'
  _git -C "$repo" tag -a v1 -m 'v1'
  apply_history_record "success" "" "$repo" "TestHost" "testuser"
  local line
  line="$(tail -1 "$(apply_history_path)")"
  local ok=1
  if ! printf '%s' "$line" | jq -e '.commitHash != null and (.commitHash|type=="string")' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.branch == "master" or .branch == "main"' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.detachedHead == false' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.appliedCommitTag == "v1"' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.lastTagOnBranch == "v1"' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.hasUnstaged == false and .hasStaged == false and .hasUntracked == false and .isDirty == false' >/dev/null 2>&1; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    assert_pass "git repo (clean, tagged) records derived fields"
  else
    assert_fail "git clean tagged derivation" "line=[$line]"
  fi

  # dirty: staged, unstaged, untracked
  rm -f "$(apply_history_path)" 2>/dev/null || true
  printf 'b\n' >>"$repo/file.txt"
  _git -C "$repo" add file.txt
  printf 'c\n' >>"$repo/file.txt"
  printf 'u\n' >"$repo/untracked.txt"
  apply_history_record "failure" "preflight" "$repo" "TestHost" "testuser"
  line="$(tail -1 "$(apply_history_path)")"
  ok=1
  if ! printf '%s' "$line" | jq -e '.hasStaged == true and .hasUnstaged == true and .hasUntracked == true and .isDirty == true' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.appliedCommitTag == "v1" and .lastTagOnBranch == "v1"' >/dev/null 2>&1; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    assert_pass "git repo (dirty staged/unstaged/untracked) records status flags"
  else
    assert_fail "git dirty status derivation" "line=[$line]"
  fi

  # detached HEAD, new commit without tag => appliedCommitTag null, lastTagOnBranch still reachable
  rm -f "$(apply_history_path)" 2>/dev/null || true
  _git -C "$repo" add -A
  _git -C "$repo" commit -qm 'second'
  _git -C "$repo" checkout -q --detach
  apply_history_record "success" "" "$repo" "TestHost" "testuser"
  line="$(tail -1 "$(apply_history_path)")"
  ok=1
  if ! printf '%s' "$line" | jq -e '.detachedHead == true' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.appliedCommitTag == null' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.lastTagOnBranch == "v1"' >/dev/null 2>&1; then ok=0; fi
  if ! printf '%s' "$line" | jq -e '.isDirty == false' >/dev/null 2>&1; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    assert_pass "git repo (detached HEAD, untagged commit) records detached/tag fields"
  else
    assert_fail "git detached/untagged derivation" "line=[$line]"
  fi

  rm -rf "$repo"
}

section 1 "record shape (non-git repoRoot)"
_t_non_git_record

section 2 "failure record carries phase"
_t_failure_phase

section 3 "trimming limits"
_t_limit_zero_disables_writes
_t_limit_positive_keeps_newest_n
_t_limit_negative_unlimited

section 4 "corrupt line reporting"
_t_corrupt_line_reported

section 5 "reader behavior"
_t_reader_json_newest_first_and_empty
_t_reader_human_latest

section 6 "git field derivation"
_t_git_repo_derivation

finish_tests
