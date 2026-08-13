#!/usr/bin/env bash
# Behavioral tests for scripts/bump-lockfile.sh: --verify stability and
# no-change write skipping (.updated is stamped only when a section changed).
#
# Run with: bash tests/scripts/bump-lockfile-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

BUMP_LOCKFILE_SCRIPT="$REPO_ROOT/scripts/bump-lockfile.sh"

# Create a fake repo ($tmp/src/lockfiles/lockfile.json) plus an empty $tmp/bin
# for stub tools; print the repo root. The fixture is a trimmed lockfile
# (2-space jq indent, trailing newline) mirroring the shape of
# src/lockfiles/lockfile.json for the sections phase 1 exercises.
setup_fake_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src/lockfiles" "$dir/bin"
  cat >"$dir/src/lockfiles/lockfile.json" <<'EOF'
{
  "$schema": "./lockfile.schema.json",
  "bun": {
    "fixture-pkg": "1.0.0"
  },
  "cargo-binstall": {
    "fixture-tool": "0.1.0"
  },
  "updated": "2026-08-02T07:16:01Z"
}
EOF
  printf '%s\n' "$dir"
}

# Run the real script against a fake repo root with stub PATH prepended, so
# fake tools win while real jq/date stay reachable.
run_bump_lockfile() {
  local repo_root="$1"
  shift
  NUCLEUS_REPO_ROOT="$repo_root" PATH="$repo_root/bin:$PATH" \
    "$BUMP_LOCKFILE_SCRIPT" "$@"
}

test_verify_passes_on_unchanged_fixture() {
  local tmp
  tmp="$(setup_fake_repo)"
  if run_bump_lockfile "$tmp" --sections cargo-binstall --verify >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile --verify exits 0 on unchanged fixture"
  else
    assert_fail "bump-lockfile --verify exits 0 on unchanged fixture" "exit code $?"
  fi
  if grep -q 'up to date' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --verify reports up to date"
  else
    assert_fail "bump-lockfile --verify reports up to date" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_verify_fails_on_section_diff() {
  local tmp
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '2.0.0\n'
EOF
  chmod +x "$tmp/bin/npm"

  if run_bump_lockfile "$tmp" --sections bun --verify >"$tmp/out.txt" 2>&1; then
    assert_fail "bump-lockfile --verify exits 1 on section diff" "expected non-zero exit"
  else
    assert_pass "bump-lockfile --verify exits 1 on section diff"
  fi
  if grep -q '2\.0\.0' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --verify diff shows the version change"
  else
    assert_fail "bump-lockfile --verify diff shows the version change" "output: $(head -1 "$tmp/out.txt")"
  fi
  if grep -q '"updated"' "$tmp/out.txt"; then
    assert_fail "bump-lockfile --verify diff has no updated-timestamp change" "updated line in diff"
  else
    assert_pass "bump-lockfile --verify diff has no updated-timestamp change"
  fi
  rm -rf "$tmp"
}

test_no_change_run_writes_nothing() {
  local tmp before after
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '1.0.0\n'
EOF
  chmod +x "$tmp/bin/npm"
  before="$(cat "$tmp/src/lockfiles/lockfile.json")"

  if run_bump_lockfile "$tmp" --sections bun >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile no-change run exits 0"
  else
    assert_fail "bump-lockfile no-change run exits 0" "exit code $?"
  fi
  after="$(cat "$tmp/src/lockfiles/lockfile.json")"
  if [ "$before" = "$after" ]; then
    assert_pass "bump-lockfile no-change run leaves file byte-identical"
  else
    assert_fail "bump-lockfile no-change run leaves file byte-identical" "file content changed"
  fi
  if grep -q 'no changes' "$tmp/out.txt"; then
    assert_pass "bump-lockfile no-change run reports no changes"
  else
    assert_fail "bump-lockfile no-change run reports no changes" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_change_run_writes_and_stamps_updated() {
  local tmp new_updated old_updated
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '2.0.0\n'
EOF
  chmod +x "$tmp/bin/npm"
  old_updated="$(jq -r '.updated' "$tmp/src/lockfiles/lockfile.json")"

  if run_bump_lockfile "$tmp" --sections bun >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile change run exits 0"
  else
    assert_fail "bump-lockfile change run exits 0" "exit code $?"
  fi
  if [ "$(jq -r '.bun["fixture-pkg"]' "$tmp/src/lockfiles/lockfile.json")" = "2.0.0" ]; then
    assert_pass "bump-lockfile change run updates the bun key"
  else
    assert_fail "bump-lockfile change run updates the bun key" "got $(jq -r '.bun["fixture-pkg"]' "$tmp/src/lockfiles/lockfile.json")"
  fi
  new_updated="$(jq -r '.updated' "$tmp/src/lockfiles/lockfile.json")"
  if [ "$new_updated" != "$old_updated" ]; then
    assert_pass "bump-lockfile change run stamps a fresh updated"
  else
    assert_fail "bump-lockfile change run stamps a fresh updated" "updated unchanged: $new_updated"
  fi
  if [[ "$new_updated" > "$old_updated" ]] || [ "$new_updated" = "$old_updated" ]; then
    assert_pass "bump-lockfile change run stamps updated >= old lexically"
  else
    assert_fail "bump-lockfile change run stamps updated >= old lexically" "new $new_updated < old $old_updated"
  fi
  if grep -q 'wrote' "$tmp/out.txt"; then
    assert_pass "bump-lockfile change run reports the write"
  else
    assert_fail "bump-lockfile change run reports the write" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_verify_passes_on_unchanged_fixture
test_verify_fails_on_section_diff
test_no_change_run_writes_nothing
test_change_run_writes_and_stamps_updated

echo ""
echo "============================================================"
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
  exit 0
fi
exit 1
