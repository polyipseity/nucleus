#!/usr/bin/env bash
# Tests sccache_cache_dir and clear_sccache_cache from lib.sh.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

. "$NUCLEUS_REPO_ROOT/src/scripts/lib/lib.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

test_sccache_cache_dir_override() {
    SCCACHE_DIR="$TEST_DIR/custom-cache" result=$(sccache_cache_dir)
    unset SCCACHE_DIR
    if [ "$result" = "$TEST_DIR/custom-cache" ]; then
        assert_pass "sccache_cache_dir: honors SCCACHE_DIR"
    else
        assert_fail "sccache_cache_dir: honors SCCACHE_DIR" "got '$result'"
    fi
}

test_clear_sccache_cache_removes_files() {
    local cache_dir="$TEST_DIR/sccache-cache"
    local fake_bin="$TEST_DIR/bin"
    mkdir -p "$cache_dir" "$fake_bin"
    printf 'marker\n' > "$cache_dir/keep-me-not"
    cat > "$fake_bin/sccache" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --stop-server) exit 0 ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "$fake_bin/sccache"

    SCCACHE_DIR="$cache_dir" PATH="$fake_bin:$PATH" clear_sccache_cache >/dev/null

    if [ -d "$cache_dir" ] && [ -z "$(ls -A "$cache_dir" 2>/dev/null || true)" ]; then
        assert_pass "clear_sccache_cache: removes cache directory contents"
    else
        assert_fail "clear_sccache_cache: removes cache directory contents" \
            "cache dir not empty: $(ls -A "$cache_dir" 2>/dev/null || true)"
    fi
}

echo "Testing lib.sh sccache gc helpers"
echo ""

test_sccache_cache_dir_override
test_clear_sccache_cache_removes_files

echo ""
echo "============================================================"
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [ "$TESTS_FAILED" -eq 0 ]; then
    exit 0
else
    exit 1
fi
