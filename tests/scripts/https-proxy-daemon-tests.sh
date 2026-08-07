#!/usr/bin/env bash
# Tests https-proxy-daemon caddy state path resolution via lib.sh.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

. "$REPO_ROOT/src/scripts/lib/lib.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

test_caddy_state_dir_from_system_log_dir() {
  export NUCLEUS_SYSTEM_LOG_DIR="$TEST_DIR/nucleus/logs"
  unset NUCLEUS_REPO_ROOT
  unset NUCLEUS_LOG_DIR

  local result
  result="$(nucleus_caddy_state_dir)"
  if [ "$result" = "$TEST_DIR/nucleus/caddy" ]; then
    assert_pass "nucleus_caddy_state_dir derives sibling caddy path from system log dir"
  else
    assert_fail "nucleus_caddy_state_dir derives sibling caddy path" "got '$result'"
  fi
}

test_daemon_creates_caddy_state_dirs() {
  export NUCLEUS_REPO_ROOT="$REPO_ROOT"
  export NUCLEUS_SYSTEM_LOG_DIR="$TEST_DIR/proxy/logs"
  unset NUCLEUS_LOG_DIR

  local state_root
  state_root="$(nucleus_caddy_state_dir)"
  mkdir -p "$state_root/config" "$state_root/data"

  if [ -d "$state_root/config" ] && [ -d "$state_root/data" ]; then
    assert_pass "caddy state config and data dirs can be created under derived root"
  else
    assert_fail "caddy state config and data dirs can be created under derived root"
  fi
}

echo "Testing https-proxy-daemon path helpers"
echo ""

test_caddy_state_dir_from_system_log_dir
test_daemon_creates_caddy_state_dirs

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
