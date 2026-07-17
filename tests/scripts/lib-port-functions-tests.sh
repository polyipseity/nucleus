#!/usr/bin/env bash
# Tests for port utility functions in src/scripts/lib.sh.
#
# Tests extract_ports() with known service registry JSON inputs.
# kill_processes_on_port and wait_for_port require live ports and
# are excluded from unit tests.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/test-lib.sh"
NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
. "$NUCLEUS_REPO_ROOT/src/scripts/lib.sh"

# Test extract_ports with a minimal service entry
test_extract_ports_basic() {
    local entry='{"network":{"ws":{"host":"127.0.0.1","port":1234,"protocol":"tcp"}}}'
    local result
    result=$(extract_ports "$entry" 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [[ "$result" == *"127.0.0.1"* && "$result" == *"1234"* ]]; then
        assert_pass "extract_ports: basic entry returns host and port"
    else
        assert_fail "extract_ports: basic entry returns host and port" "Got: $result"
    fi
}

# Test extract_ports with multiple network endpoints
test_extract_ports_multi() {
    local entry='{"network":{"default":{"host":"127.0.0.1","port":5005,"protocol":"http"},"https":{"host":"localhost","port":5006,"protocol":"https"}}}'
    local result
    result=$(extract_ports "$entry" 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [[ "$result" == *"5005"* && "$result" == *"5006"* ]]; then
        assert_pass "extract_ports: multiple endpoints return all ports"
    else
        assert_fail "extract_ports: multiple endpoints return all ports" "Got: $result"
    fi
}

# Test extract_ports with no network block
test_extract_ports_no_network() {
    local entry='{"description":"no ports"}'
    local result
    result=$(extract_ports "$entry" 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [[ -z "$result" ]]; then
        assert_pass "extract_ports: no network block returns empty"
    else
        assert_fail "extract_ports: no network block returns empty" "Got: $result"
    fi
}

# Test extract_ports with empty network block
test_extract_ports_empty_network() {
    local entry='{"network":{}}'
    local result
    result=$(extract_ports "$entry" 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [[ -z "$result" ]]; then
        assert_pass "extract_ports: empty network block returns empty"
    else
        assert_fail "extract_ports: empty network block returns empty" "Got: $result"
    fi
}

# Test extract_ports with the actual camilladsp entry from services.json
test_extract_ports_camilladsp() {
    local entry='{"network":{"websocket":{"host":"127.0.0.1","port":1234,"protocol":"tcp"}}}'
    local result
    result=$(extract_ports "$entry" 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$result" | grep -qE "^127\.0\.0\.1 +1234$"; then
        assert_pass "extract_ports: camilladsp entry produces correct output format"
    else
        assert_fail "extract_ports: camilladsp entry produces correct output format" "Got: $result"
    fi
}

echo ""
echo "Port utility function tests"
echo "==========================="
echo ""
# Run tests in order
test_extract_ports_basic
test_extract_ports_multi
test_extract_ports_no_network
test_extract_ports_empty_network
test_extract_ports_camilladsp

echo ""
echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
