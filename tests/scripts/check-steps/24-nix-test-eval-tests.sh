#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 24 nix-test-eval must flag tests that are only counted but never
# forced (silent no-ops) and 1-argument deepSeq partial applications, while
# accepting legitimate forcing constructs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/24-nix-test-eval.sh"

# Run the step's check function in a subshell; returns its exit code.
run_step24() {
  # shellcheck source=../../../src/scripts/checks/check-steps/24-nix-test-eval.sh
  ( . "$TEST_FILE"; run_24_nix_test_eval "$@" >/dev/null 2>&1 )
}

test_step24_has_register_step() {
  if grep -q 'register_step "nix-test-eval" 24' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should register as nix-test-eval"
  return 1
}

test_step24_has_partial_application_pattern() {
  # Matches: grep -nH -E '^\s*builtins\.seq\s*\(\s*builtins\.deepSeq'
  if grep -qF '^\s*builtins\.seq\s*\(\s*builtins\.deepSeq' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should detect 1-argument builtins.deepSeq partial applications"
  return 1
}

test_step24_has_length_only_pattern() {
  # Matches: builtins\.length\s+(allTests|all_tests)
  if grep -qF 'builtins\.length\s+' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should detect builtins.length counting references"
  return 1
}

test_step24_has_success_true_pattern() {
  if grep -qF 'success = true' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should look for success = true"
  return 1
}

test_step24_has_forcing_constructs_pattern() {
  # Matches: builtins\.(seq|deepSeq|all|filter) — legitimate forcing constructs
  if grep -qF 'builtins\.(seq|deepSeq|all|filter)' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should recognize legitimate forcing constructs"
  return 1
}

test_step24_has_category_c_ref() {
  if grep -q 'allow-and-deny-lists.instructions.md#C7' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should register its self-exclusion in allow-and-deny-lists Category C"
  return 1
}

test_step24_has_self_exclusion() {
  # Matches: _s24_self_sh="$(basename "${BASH_SOURCE[0]}")"
  if grep -q 'basename.*BASH_SOURCE' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should exclude its own source file"
  return 1
}

test_step24_scopes_nix_tests() {
  # Matches: case "$_f" in
  #         tests/*.nix)
  if grep -qF 'tests/*.nix)' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should only scan .nix files under tests/ in scoped mode"
  return 1
}

test_step24_excludes_lib_nix() {
  if grep -q 'lib.nix' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should exclude the shared test helper lib.nix"
  return 1
}

test_step24_uses_gitignore_filter() {
  if grep -q 'filter_gitignored' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 24 should apply the gitignore filter to its file list"
  return 1
}

test_step24_behavioral_rejects_1arg_deepseq() {
  # Behavioral: a fixture with `builtins.seq (builtins.deepSeq allTests)` must
  # fail the check (partial application never forces the tests).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat > "$_tmpdir/tests/bad-deepseq.nix" <<'EOF'
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_step24 true "$_tmpdir" "tests/bad-deepseq.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 24 should reject 1-argument builtins.deepSeq in scoped mode"
  return 1
}

test_step24_behavioral_rejects_length_only() {
  # Behavioral: a fixture that counts tests via builtins.length with no forcing
  # construct must fail the check (silent no-op).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat > "$_tmpdir/tests/bad-length-only.nix" <<'EOF'
{
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_step24 true "$_tmpdir" "tests/bad-length-only.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 24 should reject length-only counting with no forcing construct"
  return 1
}

test_step24_behavioral_accepts_2arg_deepseq() {
  # Behavioral: `builtins.seq (builtins.deepSeq allTests null)` forces the
  # tests and must pass the check.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat > "$_tmpdir/tests/good-deepseq.nix" <<'EOF'
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_step24 true "$_tmpdir" "tests/good-deepseq.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -eq 0 ]; then
    return 0
  fi
  echo "FAIL: step 24 should accept 2-argument builtins.deepSeq"
  return 1
}

test_step24_behavioral_accepts_top_level_assert() {
  # Behavioral: a top-level assert chain forces evaluation and must pass.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat > "$_tmpdir/tests/good-assert.nix" <<'EOF'
assert builtins.all (t: t == null) allTests;
{
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_step24 true "$_tmpdir" "tests/good-assert.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -eq 0 ]; then
    return 0
  fi
  echo "FAIL: step 24 should accept top-level assert forcing"
  return 1
}

test_step24_behavioral_rejects_full_mode() {
  # Behavioral: full mode must also flag a length-only no-op under tests/.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat > "$_tmpdir/tests/bad-full.nix" <<'EOF'
{
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_step24 false "$_tmpdir" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 24 should reject length-only no-ops in full mode"
  return 1
}

test_step24_behavioral_ignores_lib_nix() {
  # Behavioral: lib.nix (shared helper, not a test file) must never be flagged.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat > "$_tmpdir/tests/lib.nix" <<'EOF'
{
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_step24 false "$_tmpdir" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -eq 0 ]; then
    return 0
  fi
  echo "FAIL: step 24 should ignore lib.nix"
  return 1
}

if [ "$#" -eq 0 ] || [ "$1" = "test_step24_has_register_step" ]; then
  test_step24_has_register_step || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_has_partial_application_pattern" ]; then
  test_step24_has_partial_application_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_has_length_only_pattern" ]; then
  test_step24_has_length_only_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_has_success_true_pattern" ]; then
  test_step24_has_success_true_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_has_forcing_constructs_pattern" ]; then
  test_step24_has_forcing_constructs_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_has_category_c_ref" ]; then
  test_step24_has_category_c_ref || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_has_self_exclusion" ]; then
  test_step24_has_self_exclusion || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_scopes_nix_tests" ]; then
  test_step24_scopes_nix_tests || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_excludes_lib_nix" ]; then
  test_step24_excludes_lib_nix || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_uses_gitignore_filter" ]; then
  test_step24_uses_gitignore_filter || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_behavioral_rejects_1arg_deepseq" ]; then
  test_step24_behavioral_rejects_1arg_deepseq || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_behavioral_rejects_length_only" ]; then
  test_step24_behavioral_rejects_length_only || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_behavioral_accepts_2arg_deepseq" ]; then
  test_step24_behavioral_accepts_2arg_deepseq || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_behavioral_accepts_top_level_assert" ]; then
  test_step24_behavioral_accepts_top_level_assert || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_behavioral_rejects_full_mode" ]; then
  test_step24_behavioral_rejects_full_mode || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step24_behavioral_ignores_lib_nix" ]; then
  test_step24_behavioral_ignores_lib_nix || exit 1
fi
