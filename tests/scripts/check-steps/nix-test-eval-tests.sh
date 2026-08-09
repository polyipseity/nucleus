#!/usr/bin/env bash
# shellcheck shell=bash
# Test: nix-test-eval guard (src/scripts/lib/nix-test-eval.sh) must flag tests that
# are only counted but never forced and 1-argument deepSeq partial applications.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/lib/nix-test-eval.sh"

run_nix_test_eval_guard() {
  # shellcheck source=../../../src/scripts/lib/nix-test-eval.sh
  (
    . "$TEST_FILE"
    run_nix_test_eval "$@" >/dev/null 2>&1
  )
}

test_nix_test_eval_has_guard_function() {
  if grep -q 'run_nix_test_eval()' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: nix-test-eval lib should define run_nix_test_eval"
  return 1
}

test_nix_test_eval_has_partial_application_pattern() {
  if grep -qF '^\s*builtins\.seq\s*\(\s*builtins\.deepSeq' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: nix-test-eval lib should detect 1-argument builtins.deepSeq partial applications"
  return 1
}

test_nix_test_eval_has_length_only_pattern() {
  if grep -qF 'builtins\.length\s+' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: nix-test-eval lib should detect builtins.length counting references"
  return 1
}

test_nix_test_eval_scopes_nix_tests() {
  if grep -qF 'tests/*.nix)' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: nix-test-eval lib should only scan .nix files under tests/ in scoped mode"
  return 1
}

test_nix_test_eval_excludes_lib_nix() {
  if grep -q 'lib.nix' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: nix-test-eval lib should exclude the shared test helper lib.nix"
  return 1
}

test_nix_test_eval_uses_gitignore_filter() {
  if grep -q 'filter_gitignored' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: nix-test-eval lib should apply the gitignore filter to its file list"
  return 1
}

test_nix_test_eval_behavioral_rejects_1arg_deepseq() {
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat >"$_tmpdir/tests/bad-deepseq.nix" <<'EOF'
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_nix_test_eval_guard true "$_tmpdir" "tests/bad-deepseq.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  [ "$_exit_code" -ne 0 ]
}

test_nix_test_eval_behavioral_accepts_2arg_deepseq() {
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/tests"
  cat >"$_tmpdir/tests/good-deepseq.nix" <<'EOF'
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
}
EOF
  _exit_code=0
  run_nix_test_eval_guard true "$_tmpdir" "tests/good-deepseq.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  [ "$_exit_code" -eq 0 ]
}

for fn in \
  test_nix_test_eval_has_guard_function \
  test_nix_test_eval_has_partial_application_pattern \
  test_nix_test_eval_has_length_only_pattern \
  test_nix_test_eval_scopes_nix_tests \
  test_nix_test_eval_excludes_lib_nix \
  test_nix_test_eval_uses_gitignore_filter \
  test_nix_test_eval_behavioral_rejects_1arg_deepseq \
  test_nix_test_eval_behavioral_accepts_2arg_deepseq; do
  "$fn" || exit 1
done
