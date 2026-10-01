#!/usr/bin/env bash
# WHY: the runner detects "this step had nothing in scope" by matching the
# message text (`0 <thing> in scope; …`). That couples the runner to prose, so
# rewording any such message would silently disable the replay and the run would
# go back to showing a ✓ beside a step that did no work. This suite makes the
# coupling an enforced invariant instead: it asserts the runner's behaviour
# directly, and asserts that every step still emits a conforming message.
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
STEP_RUNNER="$REPO_ROOT/src/scripts/lib/step-runner.sh"
STEP_DIR="$REPO_ROOT/src/scripts/checks/check-steps"

require_command git "the convention scan enumerates tracked step files"

# --- behavioural: a passing step with an empty scope replays its reason ---

test_no_scope_step_replays_and_passes() {
  local _out _exit=0
  _out=$( # shellcheck disable=SC2030,SC2031 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner; the change is scoped to that subshell
    export PARALLEL_JOBS=1
    . "$STEP_RUNNER"
    # shellcheck disable=SC2329 # reason: invoked indirectly via register_step function name
    step_empty() {
      # WHY: emit through the real helper. `say` prefixes "<label>: ", so this
      # renders exactly as a production step does. An earlier `echo` here left
      # the runner's line-start anchor satisfied by the test alone, and the
      # feature it was meant to prove stayed inert in production.
      say "0 lockfile files in scope — nothing to validate."
      return 0
    }
    register_step "empty" 1 "Empty scope" step_empty
    run_all_steps
    aggregate_results
  ) 2>&1 || _exit=$?
  if [ "$_exit" -eq 0 ] && [[ "$_out" == *"0 lockfile files in scope"* ]]; then
    assert_pass "a passing step with nothing in scope replays its reason and still exits 0"
  else
    assert_fail "no-scope step replays its reason" "exit=$_exit output=[$_out]"
  fi
}

# The control. Without it, replaying every passing step would satisfy the test
# above while destroying quiet mode for the whole pipeline, so this pins the
# change to the no-scope case only.
test_ordinary_passing_step_stays_quiet() {
  local _out _exit=0
  _out=$(
    # shellcheck disable=SC2030,SC2031 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner; the change is scoped to that subshell
    export PARALLEL_JOBS=1
    . "$STEP_RUNNER"
    # shellcheck disable=SC2329 # reason: invoked indirectly via register_step function name
    step_ordinary() {
      # WHY: also via the real helper, so the control is labelled too. The change
      # under test must key on the message, not on the absence of a label.
      say "ORDINARY-STEP-OUTPUT-MARKER"
      return 0
    }
    register_step "ordinary" 1 "Ordinary" step_ordinary
    run_all_steps
    aggregate_results
  ) 2>&1 || _exit=$?
  if [ "$_exit" -eq 0 ] && [[ "$_out" != *"ORDINARY-STEP-OUTPUT-MARKER"* ]]; then
    assert_pass "a passing step with ordinary output stays unreplayed in quiet mode"
  else
    assert_fail "ordinary passing step stays quiet" "exit=$_exit output=[$_out]"
  fi
}

# The predicate must be reachable, or every assertion below reports a bare
# NOMATCH-shaped failure for a reason that has nothing to do with the message
# shape. A rename or a sourcing failure would otherwise be indistinguishable
# from the pattern being wrong. Mirrors _scan_is_live in
# tests/scripts/dead-reference-tests.sh: prove the thing under test answers at
# all before reading anything into its verdicts.
test_predicate_is_live() {
  local _tmp _result
  _tmp="$(mktemp -d)"
  (
    # shellcheck disable=SC2030,SC2031 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner; the change is scoped to that subshell
    export PARALLEL_JOBS=1
    # shellcheck disable=SC1090 # reason: $STEP_RUNNER is resolved at runtime from the repo root
    . "$STEP_RUNNER"
    if ! declare -F _step_reports_no_scope >/dev/null 2>&1; then
      printf 'NOFUNC\n'
    else
      _wave_tmpdir="$_tmp"
      _STEP_NUMBERS=(1)
      # minimal conforming line, deliberately different from the production
      # fixture below so a live control is not the same fact twice
      printf 'any-step: 0 thing in scope — nothing.\n' >"$_tmp/step-1.out"
      if _step_reports_no_scope 0; then printf 'MATCH\n'; else printf 'NOMATCH\n'; fi
    fi
  ) >"$_tmp/result.txt" 2>&1
  _result="$(cat "$_tmp/result.txt")"
  rm -rf "$_tmp"
  if [ "$_result" = "MATCH" ]; then
    assert_pass "the no-scope predicate is reachable and answers a control line"
  else
    assert_fail "the no-scope predicate is live" "result=[$_result] — the runner does not define a callable _step_reports_no_scope, or it rejects a conforming line"
  fi
}

# The tightest form of the proof: feed the predicate the exact bytes a real
# step produces. The behavioural test above passed against a `^0 ` anchor
# because it echoed a bare line; this one writes the labelled line that `say`
# actually renders, so the anchor cannot pass by satisfying the test alone.
test_predicate_matches_a_labelled_production_line() {
  local _tmp _result
  _tmp="$(mktemp -d)"
  (
    # shellcheck disable=SC2030,SC2031 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner; the change is scoped to that subshell
    export PARALLEL_JOBS=1
    # shellcheck disable=SC1090 # reason: $STEP_RUNNER is resolved at runtime from the repo root
    . "$STEP_RUNNER"
    _wave_tmpdir="$_tmp"
    _STEP_NUMBERS=(1)
    printf '05-lockfile-validation: 0 lockfile files in scope — nothing to validate.\n' \
      >"$_tmp/step-1.out"
    if _step_reports_no_scope 0; then printf 'MATCH\n'; else printf 'NOMATCH\n'; fi
  ) >"$_tmp/result.txt" 2>&1
  _result="$(cat "$_tmp/result.txt")"
  rm -rf "$_tmp"
  # WHY exact, not *MATCH*: a glob of *MATCH* also matches "NOMATCH", which
  # made this assertion pass no matter what the predicate returned.
  if [ "$_result" = "MATCH" ]; then
    assert_pass "the no-scope predicate matches a labelled production line"
  else
    assert_fail "the no-scope predicate matches a labelled production line" "result=[$_result]"
  fi
}

# The mirror of the above: the replay must not fire on ordinary output. The
# fixture is a labelled line carrying no count at all, so it exercises the
# "not a no-scope report" verdict rather than anything about anchors. Note the
# shipped pattern keeps a `^0` alternative, so a bare `0 <thing> in scope` line
# is still a match, that is intended, and a separate test covers it.
test_predicate_ignores_an_ordinary_labelled_line() {
  local _tmp _result
  _tmp="$(mktemp -d)"
  (
    # shellcheck disable=SC2030,SC2031 # reason: PARALLEL_JOBS must be set in the subshell that sources step-runner; the change is scoped to that subshell
    export PARALLEL_JOBS=1
    # shellcheck disable=SC1090 # reason: $STEP_RUNNER is resolved at runtime from the repo root
    . "$STEP_RUNNER"
    _wave_tmpdir="$_tmp"
    _STEP_NUMBERS=(1)
    printf 'check: all checks passed.\n' >"$_tmp/step-1.out"
    if _step_reports_no_scope 0; then printf 'MATCH\n'; else printf 'NOMATCH\n'; fi
  ) >"$_tmp/result.txt" 2>&1
  _result="$(cat "$_tmp/result.txt")"
  rm -rf "$_tmp"
  if [ "$_result" = "NOMATCH" ]; then
    assert_pass "ordinary passing output does not trigger the no-scope replay"
  else
    assert_fail "ordinary passing output does not trigger replay" "result=[$_result]"
  fi
}

# --- the invariant the runner's pattern depends on ---

# Every message string a step emits that mentions "in scope" must start with
# `0 ` and carry a subject, or the runner stops recognising it. Comments are
# skipped: a comment may legitimately discuss scope without being a message.
_convention_violations() {
  git -C "$REPO_ROOT" grep -h 'in scope' -- "$STEP_DIR" 2>/dev/null |
    tr -d '\r' |
    awk '
      # strip leading whitespace; a comment is prose about scope, not a message
      { line = $0; sub(/^[ \t]+/, "", line) }
      line ~ /^#/ { next }
      {
        # every single- or double-quoted string on the line is a candidate message
        n = split(line, parts, /["'"'"']/)
        for (i = 2; i <= n; i++) {
          msg = parts[i]
          if (msg !~ /in scope/) continue
          if (msg !~ /^0 .+ in scope/) print FILENAME_SEQ ":" msg
        }
      }
    '
}

test_every_in_scope_message_follows_the_convention() {
  local _violations _count _first
  _violations="$(_convention_violations)"
  if [ -z "$_violations" ]; then
    assert_pass "every 'in scope' message a step emits starts with '0 <subject> in scope'"
  else
    _count="$(printf '%s\n' "$_violations" | grep -c . || true)"
    _first="$(printf '%s\n' "$_violations" | head -1)"
    assert_fail "every 'in scope' message follows the convention" "$_count violating, first: $_first"
  fi
}

# A scan that cannot fail is not a guard. Proving the extractor sees real
# messages means an empty result above is a clean tree, not a broken filter.
test_convention_scan_sees_real_messages() {
  local _seen
  _seen="$(git -C "$REPO_ROOT" grep -h 'in scope' -- "$STEP_DIR" 2>/dev/null |
    tr -d '\r' | grep -cE "['\"]0 [^'\"]+ in scope" || true)"
  if [ "${_seen:-0}" -gt 0 ]; then
    assert_pass "the convention scan sees real messages ($_seen lines)"
  else
    assert_fail "the convention scan sees real messages" "no line matched the expected message shape"
  fi
}

test_no_scope_step_replays_and_passes
test_predicate_is_live
test_predicate_matches_a_labelled_production_line
test_predicate_ignores_an_ordinary_labelled_line
test_ordinary_passing_step_stays_quiet
test_every_in_scope_message_follows_the_convention
test_convention_scan_sees_real_messages
finish_tests
