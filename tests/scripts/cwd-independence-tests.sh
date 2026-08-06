#!/usr/bin/env bash
# Validates that derive_repo_root and all nucleus scripts resolve the repository
# root independently of the current working directory.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# Test 1: derive_repo_root works from outside the repo when SCRIPT_DIR points inside it
test_derive_repo_root_from_outside_cwd() {
    local result
    result=$(
        cd /tmp
        SCRIPT_DIR="$REPO_ROOT/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
            derive_repo_root
        '
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/scripts"
    else
        assert_fail "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/scripts" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 2: derive_repo_root from src/scripts depth works from outside repo
test_derive_repo_root_from_src_scripts() {
    local result
    result=$(
        cd /tmp
        SCRIPT_DIR="$REPO_ROOT/src/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/lib/lib.sh"
            derive_repo_root
        '
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/src/scripts"
    else
        assert_fail "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/src/scripts" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 3: NUCLEUS_REPO_ROOT env var takes priority over SCRIPT_DIR
test_env_var_priority() {
    local result
    result=$(
        cd /tmp
        SCRIPT_DIR="/nonexistent" \
        NUCLEUS_REPO_ROOT="$REPO_ROOT" \
        bash -euo pipefail -c '
            . "'"$REPO_ROOT"'/src/scripts/lib/lib.sh"
            derive_repo_root
        ' 2>/dev/null
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "NUCLEUS_REPO_ROOT env var takes priority over invalid SCRIPT_DIR"
    else
        assert_fail "NUCLEUS_REPO_ROOT env var takes priority over invalid SCRIPT_DIR" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 4: derive_repo_root fails with clear error when nothing resolves
test_derive_repo_root_fails_cleanly() {
    local derr_output
    derr_output=$(
        SCRIPT_DIR="/tmp" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            cd /tmp
            . "'"$REPO_ROOT"'/src/scripts/lib/lib.sh"
            derive_repo_root
        ' 2>&1
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$derr_output" | grep -q "cannot determine nucleus repository root"; then
        assert_pass "derive_repo_root fails with clear error when SCRIPT_DIR=/tmp"
    else
        assert_fail "derive_repo_root fails with clear error when SCRIPT_DIR=/tmp" "Output: '$derr_output'"
    fi
}

# Test 5: NUCLEUS_REPO_ROOT set to a symlink resolves to the real path
test_env_var_symlink_resolution() {
    local symlink_path
    symlink_path="$(mktemp -d)/nucleus-symlink"
    ln -s "$REPO_ROOT" "$symlink_path"
    # Clean up on exit
    trap 'rm -rf "$(dirname "$symlink_path")"' EXIT

    local result
    result=$(
        cd /tmp
        SCRIPT_DIR="$REPO_ROOT/src/scripts" \
        NUCLEUS_REPO_ROOT="$symlink_path" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/lib/lib.sh"
            derive_repo_root
        '
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "derive_repo_root resolves NUCLEUS_REPO_ROOT symlink to real path"
    else
        assert_fail "derive_repo_root resolves NUCLEUS_REPO_ROOT symlink to real path" "Expected '$REPO_ROOT', got '$result'"
    fi
    trap - EXIT
    rm -rf "$(dirname "$symlink_path")"
}

# Test 6: Scripts with --help work from outside repo
test_script_help_from_outside() {
    for script in \
        "$REPO_ROOT/scripts/gc.sh" \
        "$REPO_ROOT/scripts/health-check.sh" \
        "$REPO_ROOT/scripts/test.sh" \
        "$REPO_ROOT/scripts/svc.sh" \
        "$REPO_ROOT/scripts/vm.sh" \
        "$REPO_ROOT/scripts/update.sh" \
        "$REPO_ROOT/scripts/ai.sh" \
        "$REPO_ROOT/scripts/bootstrap.sh"; do
        local name
        name=$(basename "$script")
        # Run from /tmp with SCRIPT_DIR set so derive_repo_root can find the repo
        local result
        result=$(
            cd /tmp
            NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" bash "$script" --help 2>/dev/null
        ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
        if [ -n "$result" ]; then
            assert_pass "$name --help from /tmp"
        else
            assert_fail "$name --help from /tmp" "No output or non-zero exit"
        fi
    done
}

# Build a store-layout simulation tree (scripts/ + src/scripts/lib only).
make_store_layout_tree() {
    local marker_path="${1:-}"
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/src/scripts/lib"
    cp "$REPO_ROOT/src/scripts/lib/lib.sh" "$tmp/src/scripts/lib/lib.sh"
    if [ -n "$marker_path" ]; then
        printf '%s\n' "$marker_path" > "$tmp/.nucleus-repo-root"
    fi
    printf '%s\n' "$tmp"
}

# Test 7: store layout with marker resolves from outside repo (scripts depth)
test_store_layout_marker_from_scripts() {
    local tmp result
    tmp="$(make_store_layout_tree "$REPO_ROOT")"
    trap 'rm -rf "$tmp"' RETURN

    result=$(
        cd /tmp
        SCRIPT_DIR="$tmp/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
            derive_repo_root
        '
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "store layout with marker from /tmp with SCRIPT_DIR at scripts depth"
    else
        assert_fail "store layout with marker from /tmp with SCRIPT_DIR at scripts depth" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 8: store layout with marker resolves from outside repo (src/scripts depth)
test_store_layout_marker_from_src_scripts() {
    local tmp result
    tmp="$(make_store_layout_tree "$REPO_ROOT")"
    trap 'rm -rf "$tmp"' RETURN

    result=$(
        cd /tmp
        SCRIPT_DIR="$tmp/src/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/lib/lib.sh"
            derive_repo_root
        '
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "store layout with marker from /tmp with SCRIPT_DIR at src/scripts depth"
    else
        assert_fail "store layout with marker from /tmp with SCRIPT_DIR at src/scripts depth" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 9: store layout without marker fails cleanly
test_store_layout_without_marker_fails() {
    local tmp derr_output
    tmp="$(make_store_layout_tree)"
    trap 'rm -rf "$tmp"' RETURN

    derr_output=$(
        cd /tmp
        SCRIPT_DIR="$tmp/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
            derive_repo_root
        ' 2>&1
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$derr_output" | grep -q "cannot determine nucleus repository root"; then
        assert_pass "store layout without marker fails cleanly"
    else
        assert_fail "store layout without marker fails cleanly" "Output: '$derr_output'"
    fi
}

# Test 10: stale marker (bogus absolute path) fails cleanly
test_store_layout_stale_marker_fails() {
    local tmp derr_output
    tmp="$(make_store_layout_tree "/nonexistent/nucleus-repo-root")"
    trap 'rm -rf "$tmp"' RETURN

    derr_output=$(
        cd /tmp
        SCRIPT_DIR="$tmp/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
            derive_repo_root
        ' 2>&1
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$derr_output" | grep -q "cannot determine nucleus repository root"; then
        assert_pass "store layout with stale marker fails cleanly"
    else
        assert_fail "store layout with stale marker fails cleanly" "Output: '$derr_output'"
    fi
}

# Test 11: relative marker value fails cleanly
test_store_layout_relative_marker_fails() {
    local tmp derr_output
    tmp="$(make_store_layout_tree "./foo")"
    trap 'rm -rf "$tmp"' RETURN

    derr_output=$(
        cd /tmp
        SCRIPT_DIR="$tmp/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
            derive_repo_root
        ' 2>&1
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$derr_output" | grep -q "cannot determine nucleus repository root"; then
        assert_pass "store layout with relative marker fails cleanly"
    else
        assert_fail "store layout with relative marker fails cleanly" "Output: '$derr_output'"
    fi
}

# Test 12: empty marker file fails cleanly
test_store_layout_empty_marker_fails() {
    local tmp derr_output
    tmp="$(make_store_layout_tree "")"
    printf '' > "$tmp/.nucleus-repo-root"
    trap 'rm -rf "$tmp"' RETURN

    derr_output=$(
        cd /tmp
        SCRIPT_DIR="$tmp/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
            derive_repo_root
        ' 2>&1
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$derr_output" | grep -q "cannot determine nucleus repository root"; then
        assert_pass "store layout with empty marker fails cleanly"
    else
        assert_fail "store layout with empty marker fails cleanly" "Output: '$derr_output'"
    fi
}

# Test 13: optional e2e probe against store-installed nucleus-update
test_store_installed_nucleus_update_help() {
    local nucleus_update_path result
    if ! command -v nucleus-update >/dev/null 2>&1; then
        assert_pass "store-installed nucleus-update e2e probe skipped (nucleus-update not installed)"
        return 0
    fi
    nucleus_update_path="$(command -v nucleus-update)"
    case "$nucleus_update_path" in
        /nix/store/*)
            ;;
        *)
            assert_pass "store-installed nucleus-update e2e probe skipped (nucleus-update not in /nix/store: $nucleus_update_path)"
            return 0
            ;;
    esac

    result=$(
        cd /tmp
        env -u NUCLEUS_REPO_ROOT nucleus-update --help 2>/dev/null
    ) || true  # check-suppress:suppression_doc: test probe -- capturing output; exit code is discarded so set -e doesn't abort test
    if [ -n "$result" ]; then
        assert_pass "store-installed nucleus-update --help from /tmp without NUCLEUS_REPO_ROOT"
    else
        assert_fail "store-installed nucleus-update --help from /tmp without NUCLEUS_REPO_ROOT" "No output or non-zero exit (wrapper: $nucleus_update_path)"
    fi
}

# Run all tests
test_derive_repo_root_from_outside_cwd
test_derive_repo_root_from_src_scripts
test_env_var_priority
test_derive_repo_root_fails_cleanly
test_env_var_symlink_resolution
test_script_help_from_outside
test_store_layout_marker_from_scripts
test_store_layout_marker_from_src_scripts
test_store_layout_without_marker_fails
test_store_layout_stale_marker_fails
test_store_layout_relative_marker_fails
test_store_layout_empty_marker_fails
test_store_installed_nucleus_update_help

# Summary
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All $TESTS_PASSED cwd-independence tests passed.${NC}"
else
    echo -e "${RED}$TESTS_FAILED/$((TESTS_FAILED + TESTS_PASSED)) cwd-independence tests FAILED.${NC}" >&2
    exit 1
fi
