#!/usr/bin/env bash
# Regression tests for Nix search path warning suppression.
#
# The warning "Nix search path entry '.../channels' does not exist, ignoring"
# appeared during nucleus-apply because darwin-rebuild does:
#   export NIX_PATH=${NIX_PATH:-}
# which sets NIX_PATH to empty when unset.  An empty NIX_PATH env var
# overrides the nix-path config option (whether from nix.conf or NIX_CONFIG).
#
# The fix sets NIX_PATH=nixpkgs=flake:nixpkgs in run_nix/run_nix_as_root,
# which darwin-rebuild preserves instead of defaulting to empty.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"

# ---------------------------------------------------------------------------
# Test 1: NIX_PATH env var overrides nix-path config option
# ---------------------------------------------------------------------------
test_nix_path_overrides_config() {
    # Simulate darwin-rebuild's export NIX_PATH=${NIX_PATH:-}
    local config
    config="$(merge_nix_config)"
    export NIX_PATH=""

    local nix_path_output
    nix_path_output=$(NIX_CONFIG="$config" nix show-config 2>/dev/null | grep '^nix-path =' | head -1 || echo "")

    if [ "$nix_path_output" = "nix-path = " ]; then
        assert_pass "NIX_PATH=empty overrides nix-path config (shows empty)"
    else
        assert_fail "NIX_PATH=empty overrides nix-path config" "Expected 'nix-path = ', got '$nix_path_output'"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: Setting NIX_PATH=nixpkgs=flake:nixpkgs sets nix-path correctly
# ---------------------------------------------------------------------------
test_nix_path_set_correctly() {
    local config
    config="$(merge_nix_config)"
    export NIX_PATH="nixpkgs=flake:nixpkgs"

    local nix_path_output
    nix_path_output=$(NIX_CONFIG="$config" nix show-config 2>/dev/null | grep '^nix-path =' | head -1 || echo "")

    if [ "$nix_path_output" = "nix-path = nixpkgs=flake:nixpkgs" ]; then
        assert_pass "NIX_PATH=nixpkgs=flake:nixpkgs sets nix-path correctly"
    else
        assert_fail "NIX_PATH=nixpkgs=flake:nixpkgs sets nix-path" "Expected 'nix-path = nixpkgs=flake:nixpkgs', got '$nix_path_output'"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: Walking directory test — no search path warning when NIX_PATH set
# ---------------------------------------------------------------------------
test_no_search_path_warning_with_nix_path() {
    export NIX_PATH="nixpkgs=flake:nixpkgs"
    local config
    config="$(merge_nix_config)"

    local warning_output
    # nix eval --impure on a trivial expression; --dry-run safe
    warning_output=$(NIX_CONFIG="$config" nix eval --impure --expr '1 + 1' 2>&1 >/dev/null)
    if echo "$warning_output" | grep -qi "search path"; then
        assert_fail "no search path warning with NIX_PATH set" "Got: $warning_output"
    else
        assert_pass "no search path warning when NIX_PATH=nixpkgs=flake:nixpkgs"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: merge_nix_config does not emit nix-path
# ---------------------------------------------------------------------------
test_merge_nix_config_no_nix_path() {
    local config
    config="$(merge_nix_config)"

    if echo "$config" | grep -q "nix-path"; then
        assert_fail "merge_nix_config should not emit nix-path" "Got: $(echo "$config" | grep 'nix-path')"
    else
        assert_pass "merge_nix_config does not emit nix-path"
    fi

    if echo "$config" | grep -q "experimental-features"; then
        assert_pass "merge_nix_config still emits experimental-features"
    else
        assert_fail "merge_nix_config missing experimental-features" "Config: $config"
    fi
}

# ---------------------------------------------------------------------------
# Test 5: merge_nix_config respects external NIX_CONFIG
# ---------------------------------------------------------------------------
test_merge_nix_config_respects_external() {
    local config
    config="$(NIX_CONFIG="extra-sandbox-paths = /some/path" merge_nix_config)"

    if echo "$config" | grep -q "extra-sandbox-paths"; then
        assert_pass "merge_nix_config includes external NIX_CONFIG"
    else
        assert_fail "merge_nix_config missing external NIX_CONFIG" "Config: $config"
    fi
}

# Run all tests
test_nix_path_overrides_config
test_nix_path_set_correctly
test_no_search_path_warning_with_nix_path
test_merge_nix_config_no_nix_path
test_merge_nix_config_respects_external

# Summary
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All $TESTS_PASSED nix-search-path tests passed.${NC}"
else
    echo -e "${RED}$TESTS_FAILED/$((TESTS_FAILED + TESTS_PASSED)) nix-search-path tests FAILED.${NC}" >&2
    exit 1
fi
