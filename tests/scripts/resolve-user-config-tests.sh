#!/usr/bin/env bash
# Shell parity tests for src/scripts/lib/resolve-user-config.sh.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

RESOLVER="$REPO_ROOT/src/scripts/lib/resolve-user-config.sh"
# shellcheck source=/dev/null
. "$RESOLVER"

export NUCLEUS_REPO_ROOT="$REPO_ROOT"

test_default_starship_file() {
  local resolved expected
  resolved="$(resolve_user_config_file polyipseity starship starship.toml)"
  expected="$REPO_ROOT/src/users/default/starship/starship.toml"
  if [ "$resolved" = "$expected" ]; then
    assert_pass "resolves default starship.toml"
  else
    assert_fail "resolves default starship.toml" "got $resolved"
  fi
}

test_default_agents_dir() {
  local resolved expected
  resolved="$(resolve_user_config_dir polyipseity agents)"
  expected="$REPO_ROOT/src/users/default/agents"
  if [ "$resolved" = "$expected" ]; then
    assert_pass "resolves default agents dir"
  else
    assert_fail "resolves default agents dir" "got $resolved"
  fi
}

test_missing_file_fails() {
  if resolve_user_config_file nobody missing-config file.txt >/dev/null 2>&1; then
    assert_fail "missing file fails fast" "expected non-zero exit"
  else
    assert_pass "missing file fails fast"
  fi
}

test_default_starship_file
test_default_agents_dir
test_missing_file_fails
