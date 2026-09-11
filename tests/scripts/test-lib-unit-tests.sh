#!/usr/bin/env bash
# Unit tests for test-lib.sh (--skip-system-build removal and flag parsing).
#
# Verifies --skip-system-build is removed and step 04 runs without it.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# assert_case <label> <expected> <actual> — compare a checker's "<rc>:<reason>".
assert_case() {
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

# _tally_check <suite> <capture> <status> — run the runner-side tally checker in a
# subshell (it lives in the test-framework library, which reassigns globals) and
# echo "<rc>:<reason>".
_tally_check() {
  bash -c '
    . "'"$REPO_ROOT"'/src/scripts/tests/test-lib.sh"
    _out="$(check_suite_tally "$1" "$2" "$3")" && _rc=0 || _rc=$?
    printf "%s:%s" "$_rc" "$_out"
  ' _ "$1" "$2" "$3" 2>/dev/null
}

# ---- Spec D: --skip-system-build removal ----

# After removal, --skip-system-build must be rejected (unknown flag -> exit 1).
test_parse_args_skip_system_build_removed() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/tests/test-lib.sh"
        parse_args --skip-system-build 2>/dev/null || true
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "test-lib parse_args rejects --skip-system-build after removal"
  else
    assert_fail "tdd-ssb-reject" "Expected exit != 0 from --skip-system-build, got: $exit_code"
  fi
}

# Unknown flags must still error.
test_parse_args_no_unrecognized_flags() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/tests/test-lib.sh"
        parse_args --nonexistent-flag-x99 2>/dev/null || true
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "test-lib parse_args rejects unknown flags"
  else
    assert_fail "tdd-unknown-flag" "Expected exit != 0 from unknown flag, got: $exit_code"
  fi
}

# Usage must not mention --skip-system-build after removal.
test_test_lib_usage_no_skip_system_build() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/tests/test-lib.sh"
    usage 2>&1 || true
  )
  if ! echo "$result" | grep -q 'skip-system-build'; then
    assert_pass "usage() does not mention --skip-system-build after removal"
  else
    assert_fail "tdd-usage-no-ssb" "usage() still mentions --skip-system-build: $(echo "$result" | grep 'skip-system-build')"
  fi
}

# Every suite that sources this library must be able to fail: assertions only bump
# a counter, so a suite that never turns the tally into an exit status reports
# success to the runner no matter what it asserted.
test_all_consumers_end_with_finish_tests() {
  # Derived here rather than reusing SCRIPT_DIR/REPO_ROOT: sourcing
  # src/scripts/tests/test-lib.sh below reassigns both, so shellcheck reads them
  # as subshell-modified (SC2031) at every use outside a subshell.
  local _dir
  _dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local _file _last _missing=""
  # Two levels cover the suite directory and its subdirectories; an unmatched glob
  # stays literal, so the -f guard skips it.
  for _file in "$_dir"/*-tests.sh "$_dir"/*/*-tests.sh; do
    [ -f "$_file" ] || continue
    grep -qE '^[[:space:]]*\.[[:space:]].*test-lib\.sh' "$_file" || continue
    _last="$(awk 'NF && $1 !~ /^#/ { last = $0 } END { sub(/^[[:space:]]+/, "", last); print last }' "$_file")"
    [ "$_last" = "finish_tests" ] || _missing="$_missing $(basename "$_file")"
  done
  if [ -z "$_missing" ]; then
    assert_pass "every test-lib.sh consumer ends with finish_tests"
  else
    assert_fail "every test-lib.sh consumer ends with finish_tests" "not ending with finish_tests:$_missing"
  fi
}

# _stray_exits <file> — line numbers of `exit` statements that are not inside a
# heredoc body. A mock stub's exit belongs to another process, so only an exit
# outside a heredoc is the suite's own.
_stray_exits() {
  awk '
    {
      if (hd != "") {
        line = $0
        sub(/[[:space:]]+$/, "", line)
        if (dash) sub(/^\t+/, "", line)
        if (line == hd) { hd = "" }
        next
      }
      if (match($0, /<<-?[[:space:]]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
        tok = substr($0, RSTART, RLENGTH)
        dash = (tok ~ /^<<-/)
        sub(/^<<-?[[:space:]]*[\047"]?/, "", tok)
        sub(/[\047"]?$/, "", tok)
        hd = tok
      }
      if ($0 ~ /^[[:space:]]*exit([[:space:]]|$)/) { print FNR }
    }
  ' "$1"
}

# A suite has to prove it reached its tally: the exit status alone cannot tell
# "ran its assertions and passed" from "exited early" or "called finish_tests
# from a branch it never reaches".
test_check_suite_tally_contract() {
  local _dir _suite _capture
  _dir="$(mktemp -d)"
  _suite="$_dir/consumer-tests.sh"
  _capture="$_dir/capture.out"
  cat >"$_suite" <<'EOF'
#!/usr/bin/env bash
. "$SCRIPT_DIR/test-lib.sh"
finish_tests
EOF

  printf '# nucleus-tally passed=3 failed=0 skipped=0\n' >"$_capture"
  assert_case "tally: clean pass accepted" "0:" "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=2 failed=1 skipped=0\n' >"$_capture"
  assert_case "tally: reported failure accepted" "0:" "$(_tally_check "$_suite" "$_capture" 1)"

  : >"$_capture"
  assert_case "tally: missing tally rejected" "1:no tally (found 0)" "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=1 failed=0 skipped=0\n# nucleus-tally passed=1 failed=0 skipped=0\n' >"$_capture"
  assert_case "tally: duplicate tally rejected" "1:no tally (found 2)" "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=1 failed=2 skipped=0\n' >"$_capture"
  assert_case "tally: failed>0 with exit 0 rejected" "1:tally reports 2 failed but the suite exited 0" \
    "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=1 failed=0 skipped=0\n' >"$_capture"
  assert_case "tally: failed=0 with exit 1 rejected" "1:tally reports no failures but the suite exited 1" \
    "$(_tally_check "$_suite" "$_capture" 1)"

  # Suites that never source the consumer library have no tally to reach.
  cat >"$_dir/plain-tests.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  : >"$_capture"
  assert_case "tally: non-consumer ignored" "0:" "$(_tally_check "$_dir/plain-tests.sh" "$_capture" 0)"

  rm -rf "$_dir"
}

# finish_tests is the only sanctioned exit: an exit that bypasses it fails the
# suite without a tally, which the runner reports — but catching it here keeps a
# suite that can never reach its tally from getting that far.
test_no_consumer_exits_outside_a_heredoc() {
  local _dir _file _hits _stray=""
  _dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  for _file in "$_dir"/*-tests.sh "$_dir"/*/*-tests.sh; do
    [ -f "$_file" ] || continue
    grep -qE '^[[:space:]]*\.[[:space:]].*test-lib\.sh' "$_file" || continue
    _hits="$(_stray_exits "$_file" | tr '\n' ',')"
    [ -z "$_hits" ] || _stray="$_stray $(basename "$_file"):$_hits"
  done

  # The checker has to flag a stray exit and ignore one inside a mock stub, or
  # this assertion would pass by being blind.
  local _fixture _selftest="ok"
  _fixture="$(mktemp -d)"
  printf 'exit 0\n' >"$_fixture/stray-tests.sh"
  printf 'cat >f <<%s\n' STUBEOF >"$_fixture/stubbed-tests.sh"
  printf 'exit 0\n' >>"$_fixture/stubbed-tests.sh"
  printf '%s\n' STUBEOF >>"$_fixture/stubbed-tests.sh"
  [ -n "$(_stray_exits "$_fixture/stray-tests.sh")" ] || _selftest="blind"
  [ -z "$(_stray_exits "$_fixture/stubbed-tests.sh")" ] || _selftest="noisy"
  rm -rf "$_fixture"

  if [ "$_selftest" = ok ] && [ -z "$_stray" ]; then
    assert_pass "no test-lib.sh consumer exits outside a heredoc"
  else
    assert_fail "no test-lib.sh consumer exits outside a heredoc" "checker=$_selftest stray:$_stray"
  fi
}

# ---- Run tests ----
section 1 "Phase 2: test-lib unit tests"
echo ""

test_parse_args_skip_system_build_removed
test_parse_args_no_unrecognized_flags
test_test_lib_usage_no_skip_system_build
test_all_consumers_end_with_finish_tests
test_check_suite_tally_contract
test_no_consumer_exits_outside_a_heredoc

finish_tests
