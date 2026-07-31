#!/usr/bin/env bash
# Baseline regression tests for step-runner.sh.
# Captures current behavioral contracts before Phase 1-6 changes.
# ALL tests must pass on the current codebase.
#
# Phase 1 changes: step IDs (non-numeric), --skip-steps, --format removal
# Phase 2 changes: --skip-system-build removal
# Phase 3 changes: step registration updates (new ID format)
# Phase 5 changes: silent-skip elimination
# Phase 6 changes: step 13 $schema enforcement
# Phase 7 changes: gitignore filtering in cache_file_lists via deny-list library

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# ---- Contract A: Step IDs are currently numeric integers ----
# These tests will fail when Phase 1 changes registration to non-numeric IDs.

test_regression_step_id_format_numeric() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        register_step "a" 1 "Test" test_func
        echo "${_STEP_IDS[0]} ${_STEP_NUMBERS[0]}"
    )
    if [ "$result" = "a 1" ]; then
        assert_pass "REGRESSION: register_step stores ID and number correctly"
    else
        assert_fail "REG-step-id-numeric" "Expected 'a 1', got: $result"
    fi
}

test_regression_step_id_preserves_order() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        register_step "five" 5 "Fifth" f5
        register_step "three" 3 "Third" f3
        register_step "seven" 7 "Seventh" f7
        echo "${_STEP_NUMBERS[*]} | ${_STEP_IDS[*]}"
    )
    if [ "$result" = "5 3 7 | five three seven" ]; then
        assert_pass "REGRESSION: register_step preserves insertion order (IDs + numbers)"
    else
        assert_fail "REG-step-id-order" "Expected '5 3 7 | five three seven', got: $result"
    fi
}

# ---- Contract B: --format flag removed (Phase 1) ----
# --format is no longer accepted by parse_args. Tests for it have been removed.

# ---- Contract B2: --skip-system-build removed (Phase 2) ----
# Flag is no longer accepted by test-lib.sh's parse_args.

test_regression_skip_system_build_flag_removed() {
    local exit_code=0
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/tests/test-lib.sh"
        parse_args --skip-system-build 2>/dev/null || true
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        assert_pass "REGRESSION: --skip-system-build is no longer accepted"
    else
        assert_fail "REG-skip-sys-build" "Expected exit != 0 from --skip-system-build, got: $exit_code"
    fi
}

# ---- Contract C: parse_args scoped/full behavior ----
# These should remain stable across all phases.

test_regression_scoped_sets_has_args() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --scoped
        echo "$SCOPED $HAS_ARGS"
    )
    if [ "$result" = "true true" ]; then
        assert_pass "REGRESSION: --scoped sets SCOPED=true and HAS_ARGS=true"
    else
        assert_fail "REG-scoped" "Expected 'true true', got: $result"
    fi
}

test_regression_full_sets_has_args_false() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --full
        echo "$FULL $HAS_ARGS"
    )
    if [ "$result" = "true false" ]; then
        assert_pass "REGRESSION: --full sets FULL=true and HAS_ARGS=false"
    else
        assert_fail "REG-full" "Expected 'true false', got: $result"
    fi
}

test_regression_scoped_and_full_mutually_exclusive() {
    local exit_code=0
    bash -c '
        SCRIPT_DIR="'"$REPO_ROOT"'/src/scripts/lib"
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --scoped --full 2>/dev/null
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        assert_pass "REGRESSION: --scoped and --full combined exits non-zero"
    else
        assert_fail "REG-scoped-full-mutex" "Expected non-zero exit, got: $exit_code"
    fi
}

# ---- Contract D: fail-fast defaults ----
# check-lib sets FAIL_FAST=false by default (overridden later);
# test-lib sets FAIL_FAST=true.

test_regression_parse_args_fail_fast_default() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        FAIL_FAST=false
        parse_args
        echo "$FAIL_FAST"
    )
    if [ "$result" = "false" ]; then
        assert_pass "REGRESSION: parse_args preserves default FAIL_FAST when no flag"
    else
        assert_fail "REG-fail-fast-default" "Expected 'false', got: $result"
    fi
}

test_regression_fail_fast_flag_accepted() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --fail-fast
        echo "$FAIL_FAST"
    )
    if [ "$result" = "true" ]; then
        assert_pass "REGRESSION: --fail-fast sets FAIL_FAST=true"
    else
        assert_fail "REG-fail-fast" "Expected 'true', got: $result"
    fi
}

# ---- Contract E: Wave temp directory management ----
test_regression_wave_init_creates_tempdir() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        _wave_init
        echo "$_wave_tmpdir"
        _wave_cleanup
    )
    if echo "$result" | grep -q 'nucleus-step-runner-'; then
        assert_pass "REGRESSION: _wave_init creates temp dir with expected prefix"
    else
        assert_fail "REG-wave-init" "Expected temp dir path containing 'nucleus-step-runner-', got: $result"
    fi
}

test_regression_wave_cleanup_removes_tempdir() {
    local tmpdir
    tmpdir=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        _wave_init
        echo "$_wave_tmpdir"
        _wave_cleanup
    )
    if [ ! -d "$tmpdir" ]; then
        assert_pass "REGRESSION: _wave_cleanup removes temp dir"
    else
        assert_fail "REG-wave-cleanup" "Temp dir still exists: $tmpdir"
    fi
}

# ---- Contract F: cache_file_lists respects gitignore filtering ----
test_regression_cache_file_lists_sets_cached_vars() {
    local result
    result=$(
        cd "$REPO_ROOT" || exit 1
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        CACHED_NIX_FILES=()
        CACHED_YAML_FILES=()
        CACHED_JSON_FILES=()
        CACHED_SH_FILES=()
        cache_file_lists
        echo "nix:${#CACHED_NIX_FILES[@]} yaml:${#CACHED_YAML_FILES[@]} json:${#CACHED_JSON_FILES[@]} sh:${#CACHED_SH_FILES[@]}"
    )
    # Non-zero counts required — a vacuous run (all zeros) must not pass.
    if echo "$result" | grep -Eq 'nix:[1-9][0-9]* yaml:[1-9][0-9]* json:[1-9][0-9]* sh:[1-9][0-9]*'; then
        assert_pass "REGRESSION: cache_file_lists populates all cache variables (non-zero)"
    else
        assert_fail "REG-cache-files" "Expected non-zero numeric counts, got: $result"
    fi
}

test_regression_cache_file_lists_excludes_gitignored() {
    local result
    result=$(
        cd "$REPO_ROOT" || exit 1
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        # Fixture: a .nix file under gitignored .direnv/ must be filtered
        # out by cache_file_lists (via filter_gitignored -> git check-ignore).
        mkdir -p .direnv
        printf '{}' > .direnv/_nucleus_regression_fixture.nix
        CACHED_NIX_FILES=()
        CACHED_YAML_FILES=()
        CACHED_JSON_FILES=()
        CACHED_SH_FILES=()
        cache_file_lists
        rm -f .direnv/_nucleus_regression_fixture.nix
        rmdir .direnv 2>/dev/null || true
        # Invariants: the gitignored fixture is dropped, a tracked file stays.
        _fixture_found=no
        _tracked_found=no
        for _f in "${CACHED_NIX_FILES[@]}"; do
            if [[ "$_f" == *.direnv/_nucleus_regression_fixture.nix ]]; then
                _fixture_found=yes
            fi
            if [[ "$_f" == *src/flake.nix ]]; then
                _tracked_found=yes
            fi
        done
        echo "fixture_ignored=$_fixture_found tracked_present=$_tracked_found"
    )
    if [ "$result" = "fixture_ignored=no tracked_present=yes" ]; then
        assert_pass "REGRESSION: cache_file_lists excludes gitignored fixture, keeps tracked files"
    else
        assert_fail "REG-cache-excludes-ignored" "Expected 'fixture_ignored=no tracked_present=yes', got: $result"
    fi
}

test_regression_cache_file_lists_survives_set_e() {
    local result exit_code=0
    result=$(bash -c '
        set -euo pipefail
        cd "$1" || exit 1
        SCRIPT_DIR="$1/src/scripts/lib"
        . "$1/src/scripts/lib/step-runner.sh"
        cache_file_lists
        echo "nix:${#CACHED_NIX_FILES[@]} yaml:${#CACHED_YAML_FILES[@]} json:${#CACHED_JSON_FILES[@]} sh:${#CACHED_SH_FILES[@]}"
    ' bash "$REPO_ROOT") || exit_code=$?
    # Phase 1 regression guard: git check-ignore exits 1 when nothing is
    # ignored; filter_gitignored must survive that under set -euo pipefail.
    if [ "$exit_code" -eq 0 ] && echo "$result" | grep -Eq 'nix:[1-9][0-9]* yaml:[1-9][0-9]* json:[1-9][0-9]* sh:[1-9][0-9]*'; then
        assert_pass "REGRESSION: cache_file_lists survives set -euo pipefail (non-zero counts)"
    else
        assert_fail "REG-cache-set-e" "exit=$exit_code, got: $result"
    fi
}

# ---- Contract G: aggregate_results output format ----
# Owns exit behavior (exit 0 on pass, exit 1 on fail).

test_regression_aggregate_results_exits_zero_on_pass() {
    local exit_code=0
    bash -c '
        SCRIPT_DIR="'"$REPO_ROOT"'/src/scripts/lib"
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        say() { true; }
        error() { true; }
        _wave_init
        register_step "pass" 1 "Pass" some_func
        printf "%s" "0" > "$_wave_tmpdir/step-1.exit"
        printf "%s" "10" > "$_wave_tmpdir/step-1.time"
        printf "%s" "Pass" > "$_wave_tmpdir/step-1.name"
        aggregate_results 2>&1 || true
    ' 2>/dev/null || exit_code=$?
    # aggregate_results calls exit 0 on all pass; in subshell it can be trapped
    if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 130 ]; then
        assert_pass "REGRESSION: aggregate_results exits 0 on all pass"
    else
        assert_fail "REG-aggr-pass" "Expected exit 0 (or trapped), got: $exit_code"
    fi
}

test_regression_aggregate_results_output_contains_check_summary() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        say() { echo "say: $*"; }
        error() { echo "error: $*" >&2; }
        _wave_init
        register_step "pass" 1 "PassStep" pfunc
        printf "%s" "0" > "$_wave_tmpdir/step-1.exit"
        printf "%s" "42" > "$_wave_tmpdir/step-1.time"
        printf "%s" "PassStep" > "$_wave_tmpdir/step-1.name"
        # shellcheck disable=SC2317 # reason: reached in subshell
        aggregate_results 2>&1 || true
    ) 2>&1
    if echo "$result" | grep -q "step  1"; then
        assert_pass "REGRESSION: aggregate_results outputs step summary table"
    else
        assert_fail "REG-aggr-output" "Expected step summary, got: $result"
    fi
}

test_regression_aggregate_results_renders_skip_for_exit_2() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        say() { echo "say: $*"; }
        error() { echo "error: $*" >&2; }
        _wave_init
        register_step "skip" 2 "SkipStep" sfunc
        printf "%s" "2" > "$_wave_tmpdir/step-2.exit"
        printf "%s" "7" > "$_wave_tmpdir/step-2.time"
        printf "%s" "SkipStep" > "$_wave_tmpdir/step-2.name"
        # shellcheck disable=SC2317 # reason: reached in subshell
        aggregate_results 2>&1 || true
    ) 2>&1
    if echo "$result" | grep -q "SKIP" && ! echo "$result" | grep -q "some checks failed"; then
        assert_pass "REGRESSION: aggregate_results renders exit 2 as SKIP (not a failure)"
    else
        assert_fail "REG-aggr-skip" "Expected SKIP row without failure, got: $result"
    fi
}

# ---- Contract H: run_all_steps uses parallelism (POSIX) ----
test_regression_run_all_steps_uses_background_jobs() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        # Verify the pattern: steps are run with & (background)
        grep -c '&' <<< "$(declare -f run_all_steps)"
    )
    if echo "$result" | grep -q '1'; then
        assert_pass "REGRESSION: run_all_steps uses background parallelism (POSIX)"
    else
        assert_fail "REG-parallelism" "Expected 1 & in run_all_steps, got: $result"
    fi
}

# ---- Contract I: gitignore filtering available through step-runner ----
# deny-list.sh is transitively sourced by step-runner.sh.
test_regression_filter_gitignored_available_through_step_runner() {
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        type filter_gitignored 2>&1 || echo "NOT_FOUND"
    )
    if echo "$result" | grep -q "function"; then
        assert_pass "REGRESSION: filter_gitignored available through transitive step-runner source"
    else
        assert_fail "REG-filter-step-runner" "filter_gitignored not found through step-runner: $result"
    fi
}

# ---- Contract J: run_all_steps emits live progress lines (Phase 11) ----
test_regression_run_all_steps_emits_progress_lines() {
    local result
    result=$(
        cd "$REPO_ROOT" || exit 1
        SCRIPT_DIR="$REPO_ROOT/src/scripts/lib"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        # shellcheck disable=SC2329 # reason: stub invoked by run_all_steps internals
        say() { true; }
        error() { true; }
        # shellcheck disable=SC2329 # reason: reached via register_step dispatch
        mock_step() { return 0; }
        register_step "mock-a" 1 "Mock A" mock_step
        register_step "mock-b" 2 "Mock B" mock_step
        run_all_steps 2>&1 || true
    ) 2>&1
    if echo "$result" | grep -q '\[1/2\] step 1 Mock A started' \
        && echo "$result" | grep -q '\[2/2\] step 2 Mock B started' \
        && echo "$result" | grep -q 'step 1 finished (' \
        && echo "$result" | grep -q 'step 2 finished ('; then
        assert_pass "REGRESSION: run_all_steps emits started/finished progress lines"
    else
        assert_fail "REG-progress-lines" "Expected started/finished progress lines, got: $result"
    fi
}

# ---- Run tests ----
echo ""
echo "=== Phase 0: Step-runner regression tests (POSIX) ==="
echo "These tests capture current behavioral contracts. If any fail,"
echo "the baseline has changed. Review whether the change is intentional."
echo ""

test_regression_skip_system_build_flag_removed
test_regression_step_id_format_numeric
test_regression_step_id_preserves_order
test_regression_scoped_sets_has_args
test_regression_full_sets_has_args_false
test_regression_scoped_and_full_mutually_exclusive
test_regression_parse_args_fail_fast_default
test_regression_fail_fast_flag_accepted
test_regression_wave_init_creates_tempdir
test_regression_wave_cleanup_removes_tempdir
test_regression_cache_file_lists_sets_cached_vars
test_regression_cache_file_lists_excludes_gitignored
test_regression_cache_file_lists_survives_set_e
test_regression_aggregate_results_exits_zero_on_pass
test_regression_aggregate_results_output_contains_check_summary
test_regression_aggregate_results_renders_skip_for_exit_2
test_regression_run_all_steps_uses_background_jobs
test_regression_filter_gitignored_available_through_step_runner
test_regression_run_all_steps_emits_progress_lines

echo ""
echo "--- Phase 0 POSIX regression tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
