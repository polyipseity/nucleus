#!/usr/bin/env bash
# shellcheck shell=bash
# Test: nix-test-eval guard (src/scripts/lib/nix-test-eval.sh) must flag tests that
# are only counted but never forced and 1-argument deepSeq partial applications.
# All grep-only tests (that checked implementation text) have been removed.

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
  test_nix_test_eval_behavioral_rejects_1arg_deepseq \
  test_nix_test_eval_behavioral_accepts_2arg_deepseq; do
  "$fn" || exit 1
done
