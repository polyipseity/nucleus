#!/usr/bin/env bash
# Unit tests for test-lib.sh (--skip-system-build removal and flag parsing).
#
# Verifies --skip-system-build is removed and step 04 runs without it.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# assert_case <label> <expected> <actual>: compare a checker's "<rc>:<reason>".
assert_case() {
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

# _tally_check <suite> <capture> <status>: run the runner-side tally checker in a
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

# _stray_exits <file>: line numbers of `exit` statements that are not inside a
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

  printf '# nucleus-tally passed=3 failed=0\n' >"$_capture"
  assert_case "tally: clean pass accepted" "0:" "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=2 failed=1\n' >"$_capture"
  # A failing suite must be named as failing: a bare path in the runner's list
  # says nothing about how many assertions failed.
  assert_case "tally: reported failure is named" "1:tally reports 1 failed" "$(_tally_check "$_suite" "$_capture" 1)"

  : >"$_capture"
  assert_case "tally: missing tally rejected" "1:no tally (found 0)" "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=1 failed=0\n# nucleus-tally passed=1 failed=0\n' >"$_capture"
  assert_case "tally: duplicate tally rejected" "1:no tally (found 2)" "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=1 failed=2\n' >"$_capture"
  assert_case "tally: failed>0 with exit 0 rejected" "1:tally reports 2 failed but the suite exited 0" \
    "$(_tally_check "$_suite" "$_capture" 0)"

  printf '# nucleus-tally passed=1 failed=0\n' >"$_capture"
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
# suite without a tally, which the runner reports, but catching it here keeps a
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

# ---- safe-rm fixture environment ----

# The cases must not depend on a provisioned host: safe-rm is installed by the
# install-bun-packages activation, it is absent from the test app's
# runtimeInputs, and CI runs bootstrap --no-apply before the test pipeline, so a
# case that needs the real binary would be red on every CI runner. A fake with
# the tool's contract (read SAFE_RM_CONFIG, move each target into SAFE_RM_TRASH,
# prompt when the trash is absent) exercises the helper identically on any host,
# and a PATH without it at all exercises the absent branch even here.

# Derived from this file rather than reused from SCRIPT_DIR: sourcing
# src/scripts/tests/test-lib.sh in the probes below reassigns SCRIPT_DIR, which
# makes shellcheck read every later use as possibly lost (SC2031).
_SAFE_RM_TEST_LIB="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib.sh"

_make_fake_safe_rm() { # <dir>
  # shellcheck disable=SC2016 # reason: the quoted body is a script for the shim, not text this shell expands
  cat >"$1/safe-rm" <<'FAKE'
#!/usr/bin/env bash
# Stand-in for safe-rm: fails unless the helper configured a config file, then
# moves every operand into the configured trash, which is the part of safe-rm's
# behaviour the helper is responsible for. An absent trash takes the tool's own
# route (safe-rm bin/rm.sh:389-398): print the prompt, read stdin, then create
# and proceed, so at EOF the prompt has already reached stdout.
set -eu
[ -f "$SAFE_RM_CONFIG" ]
if [ ! -d "$SAFE_RM_TRASH" ]; then
  printf 'Directory "%s" does not exist, do you want create it? ' "$SAFE_RM_TRASH"
  IFS= read -r _answer || :
fi
mkdir -p "$SAFE_RM_TRASH"
for _target in "$@"; do
  case "$_target" in -*) continue ;; esac
  mv -- "$_target" "$SAFE_RM_TRASH/"
done
FAKE
  chmod +x "$1/safe-rm"
}

_SAFE_RM_FAKE_BIN="$(mktemp -d)"
_make_fake_safe_rm "$_SAFE_RM_FAKE_BIN"
# One trash for the whole run, which is what a suite gets: it calls the helper in
# its own shell first, so every child process inherits the cached directory.
_SAFE_RM_PROBE_TRASH="$(mktemp -d)"

# Each case below runs in a fresh shell so the helper's exports cannot leak into
# the suite's own environment, and so its PATH is the one the case names.
_lib_probe() { # <path> [assignment...]
  local _path="$1"
  shift
  # shellcheck disable=SC2016 # reason: the quoted body is a script for bash -c, not text this shell expands
  env -u SAFE_RM_CONFIG -u SAFE_RM_TRASH "$@" PATH="$_path" \
    _NUCLEUS_TEST_SAFE_RM_TRASH="$_SAFE_RM_PROBE_TRASH" bash -c '
    . "$1"
    ensure_safe_rm_env && _rc=0 || _rc=$?
    printf "%s|%s|%s" "$_rc" "${SAFE_RM_CONFIG-}" "${SAFE_RM_TRASH-}"
  ' _ "$_SAFE_RM_TEST_LIB"
}

# With nothing exported, both variables must point at paths that exist: a config
# safe-rm can source, and a scratch trash. A trash that does not exist is what
# makes safe-rm prompt on stdout and corrupt every exact-output assertion.
test_ensure_safe_rm_env_sets_both_when_unset() {
  local _result _rc _config _trash
  _result="$(_lib_probe "$_SAFE_RM_FAKE_BIN:$PATH")"
  _rc="${_result%%|*}"
  _result="${_result#*|}"
  _config="${_result%%|*}"
  _trash="${_result#*|}"
  if [ "$_rc" = 0 ] && [ -f "$_config" ] && [ -d "$_trash" ] &&
    [ "$_trash" != "$HOME/.Trash" ] &&
    case "$_config" in */tests/fixtures/safe-rm/config) true ;; *) false ;; esac then
    assert_pass "ensure_safe_rm_env points at the fixture config and a scratch trash"
  else
    assert_fail "ensure_safe_rm_env points at the fixture config and a scratch trash" \
      "rc=$_rc config=[$_config] trash=[$_trash]"
  fi
}

# A caller that sets both keeps its own pair: the check gate supplies the
# operator's real config this way, and silently replacing it would hide a broken
# operator config from the gate. The fake is on PATH so the honored-pair branch
# is actually reached rather than skipped by an absent binary.
test_ensure_safe_rm_env_keeps_a_complete_pair() {
  local _result
  _result="$(_lib_probe "$_SAFE_RM_FAKE_BIN:$PATH" \
    SAFE_RM_CONFIG=/sentinel/config SAFE_RM_TRASH=/sentinel/trash)"
  if [ "$_result" = "0|/sentinel/config|/sentinel/trash" ]; then
    assert_pass "ensure_safe_rm_env keeps a caller's complete pair"
  else
    assert_fail "ensure_safe_rm_env keeps a caller's complete pair" "got [$_result]"
  fi
}

# A half pair is completed and the supplied half survives, in both directions.
# The supplied config without a trash is the case that prompted on this host;
# the supplied trash without a config is the mirror, and neither half may be
# replaced by the helper.
test_ensure_safe_rm_env_completes_a_half_pair() {
  local _result _config _trash
  _result="$(_lib_probe "$_SAFE_RM_FAKE_BIN:$PATH" SAFE_RM_CONFIG=/sentinel/config)"
  _result="${_result#0|}"
  _config="${_result%%|*}"
  _trash="${_result#*|}"
  if [ "$_config" = /sentinel/config ] && [ -d "$_trash" ]; then
    assert_pass "ensure_safe_rm_env keeps a supplied config and adds a trash"
  else
    assert_fail "ensure_safe_rm_env keeps a supplied config and adds a trash" \
      "config=[$_config] trash=[$_trash]"
  fi

  _result="$(_lib_probe "$_SAFE_RM_FAKE_BIN:$PATH" SAFE_RM_TRASH=/sentinel/trash)"
  _result="${_result#0|}"
  _config="${_result%%|*}"
  _trash="${_result#*|}"
  if [ -f "$_config" ] && [ "$_trash" = /sentinel/trash ]; then
    assert_pass "ensure_safe_rm_env keeps a supplied trash and adds a config"
  else
    assert_fail "ensure_safe_rm_env keeps a supplied trash and adds a config" \
      "config=[$_config] trash=[$_trash]"
  fi
}

# Two calls in one shell hand back the same directory. Without the cache every
# call and every child process added another trash directory, which is the leak
# the unit suite showed three times over.
test_ensure_safe_rm_env_reuses_one_trash_per_run() {
  local _result
  # The second call clears the pair first, or the complete-pair branch would
  # return before the cache is consulted and this would pass for the wrong
  # reason.
  # shellcheck disable=SC2016 # reason: the quoted body is a script for bash -c, not text this shell expands
  _result="$(env -u SAFE_RM_CONFIG -u SAFE_RM_TRASH -u _NUCLEUS_TEST_SAFE_RM_TRASH \
    PATH="$_SAFE_RM_FAKE_BIN:$PATH" bash -c '
    . "$1"
    ensure_safe_rm_env
    _first="$SAFE_RM_TRASH"
    unset SAFE_RM_CONFIG SAFE_RM_TRASH
    ensure_safe_rm_env
    printf "%s|%s|%s" "$_first" "$SAFE_RM_TRASH" "$SAFE_RM_CONFIG"
  ' _ "$_SAFE_RM_TEST_LIB")"
  local _first _rest _second
  _first="${_result%%|*}"
  _rest="${_result#*|}"
  _second="${_rest%%|*}"
  if [ -n "$_first" ] && [ "$_first" = "$_second" ] && [ -d "$_first" ]; then
    assert_pass "ensure_safe_rm_env reuses one trash directory per run"
  else
    assert_fail "ensure_safe_rm_env reuses one trash directory per run" "got [$_result]"
  fi
}

# Without safe-rm on PATH there is nothing to configure: `rm` is the plain one,
# asks nothing, and keeps no trash, so the suite is already hermetic. The helper
# says so in one line instead of failing, because CI provisions safe-rm nowhere
# (bootstrap installs Nix and base deps, the test app adds no PATH) and a hard
# failure here would be six suite reds for a host that needs no configuration.
# The cases above are the control that keeps this from passing against a helper
# that never exports anything.
test_ensure_safe_rm_env_leaves_a_plain_rm_alone() {
  local _result
  # The interpreter is named by absolute path and PATH holds nothing resolvable:
  # /usr/bin:/bin does not exist on NixOS, where looking bash up in that PATH
  # exits 127 and set -e aborts the suite before its tally.
  # The notice is captured in the same string as the exports, so the assertion
  # matches the full shape it claims: no exports, status 0, then the notice.
  # shellcheck disable=SC2016 # reason: the quoted body is a script for bash -c, not text this shell expands
  _result="$(env -u SAFE_RM_CONFIG -u SAFE_RM_TRASH -u _NUCLEUS_TEST_SAFE_RM_TRASH \
    PATH=/nonexistent "$BASH" -c '
    . "$1"
    _notice="$(ensure_safe_rm_env)" && _rc=0 || _rc=$?
    printf "|%s|%s|%s|%s" "${SAFE_RM_CONFIG-}" "${SAFE_RM_TRASH-}" "$_rc" "$_notice"
  ' _ "$_SAFE_RM_TEST_LIB")"
  case "$_result" in
  "|||0|"*"safe-rm not found, deletions run through the plain rm")
    assert_pass "ensure_safe_rm_env leaves a plain rm alone and says so"
    ;;
  *)
    assert_fail "ensure_safe_rm_env leaves a plain rm alone and says so" "got [$_result]"
    ;;
  esac
}

# The point of the helper is the deletion route, so exercise it on the helper's
# own path: no injected trash, so the creation and export branch runs, the tool
# receives a config it can read and the trash the helper made, the output is
# exactly the trash path (a prompt would corrupt it), and the delete lands in the
# exported directory a child process inherits.
test_ensure_safe_rm_env_routes_a_delete_to_the_scratch_trash() {
  local _work _out _rc=0
  _work="$(mktemp -d)"
  printf 'victim\n' >"$_work/victim"
  # Exit statuses name the failed step, so a red run reports which one broke
  # instead of only that the probe printed nothing; 5 is the export never
  # reaching the child environment. stdin sits at /dev/null so a prompt hits EOF
  # at once instead of waiting on the suite's own stdin.
  # shellcheck disable=SC2016 # reason: the quoted body is a script for bash -c, not text this shell expands
  _out="$(env -u SAFE_RM_CONFIG -u SAFE_RM_TRASH -u _NUCLEUS_TEST_SAFE_RM_TRASH \
    PATH="$_SAFE_RM_FAKE_BIN:$PATH" bash -c '
    . "$1"
    ensure_safe_rm_env || exit 9
    _exported="$(env | sed -n "s/^_NUCLEUS_TEST_SAFE_RM_TRASH=//p")"
    [ -n "$_exported" ] && [ "$_exported" = "$SAFE_RM_TRASH" ] || exit 5
    safe-rm -f "$2" || exit 8
    [ -e "$2" ] && exit 7
    [ -e "$_exported/victim" ] || exit 6
    printf "%s" "$SAFE_RM_TRASH"
  ' _ "$_SAFE_RM_TEST_LIB" "$_work/victim" </dev/null)" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    assert_fail "ensure_safe_rm_env routes a delete to the scratch trash" "probe exited $_rc"
  elif [ -z "$_out" ]; then
    assert_fail "ensure_safe_rm_env routes a delete to the scratch trash" \
      "the trash path is empty"
  elif [ -d "$_out" ] && [ ! -e "$_work/victim" ] && [ "$_out" != "$HOME/.Trash" ]; then
    assert_pass "ensure_safe_rm_env routes a delete to the scratch trash"
  else
    assert_fail "ensure_safe_rm_env routes a delete to the scratch trash" "trash=[$_out]"
  fi
  rm -rf "$_work"
}

# The absent-trash prompt is the failure class the helper exists to prevent:
# safe-rm's bin/rm.sh:389-398 prints the prompt on stdout, reads stdin, then
# creates the trash and proceeds, and the prompt on stdout is what corrupts a
# suite's exact-output assertions. CI carries no real binary (fixture note
# above), so the fake carries the same route, and this case pins it: a supplied
# trash path that does not exist must produce the prompt and still lose the file
# to the trash.
test_safe_rm_route_prompts_on_an_absent_trash() {
  local _work _trash _out _rc=0
  _work="$(mktemp -d)"
  printf 'victim\n' >"$_work/victim"
  _trash="$_work/absent-trash"
  # shellcheck disable=SC2016 # reason: the quoted body is a script for bash -c, not text this shell expands
  _out="$(env -u SAFE_RM_CONFIG -u SAFE_RM_TRASH \
    PATH="$_SAFE_RM_FAKE_BIN:$PATH" _NUCLEUS_TEST_SAFE_RM_TRASH="$_trash" bash -c '
    . "$1"
    ensure_safe_rm_env || exit 9
    safe-rm -f "$2" || exit 8
    [ -e "$2" ] && exit 7
    [ -e "$3/victim" ] || exit 6
  ' _ "$_SAFE_RM_TEST_LIB" "$_work/victim" "$_trash" </dev/null)" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    assert_fail "safe-rm route prompts on an absent trash" "probe exited $_rc"
  else
    case "$_out" in
    *"do you want create it"*)
      assert_pass "safe-rm route prompts on an absent trash"
      ;;
    *)
      assert_fail "safe-rm route prompts on an absent trash" "no prompt in [$_out]"
      ;;
    esac
  fi
  rm -rf "$_work"
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
test_ensure_safe_rm_env_sets_both_when_unset
test_ensure_safe_rm_env_keeps_a_complete_pair
test_ensure_safe_rm_env_completes_a_half_pair
test_ensure_safe_rm_env_reuses_one_trash_per_run
test_ensure_safe_rm_env_leaves_a_plain_rm_alone
test_ensure_safe_rm_env_routes_a_delete_to_the_scratch_trash
test_safe_rm_route_prompts_on_an_absent_trash

finish_tests
