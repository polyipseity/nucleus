#!/usr/bin/env bash
# Regression test: lib.sh must source without referencing functions before they
# are defined. The 2026-08 bug called derive_nucleus_user_root at the top of the
# file (to set NUCLEUS_USER_ROOT) while defining it near the bottom, so every
# script that sourced lib.sh failed with "command not found" and an empty root.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"

# Source lib.sh in a clean subshell with an optional env prefix (space-separated
# VAR=value pairs). $0 is pinned to nucleus-lib-test so the derived command
# prefix stays deterministic. The env prefix is embedded as plain assignments so
# word splitting is intentional; `:` no-ops when empty.
_run_lib() {
  local env_prefix="$1" cmd="$2"
  bash -c "${env_prefix:-:}; . \"\$1\"; eval \"\$2\"" nucleus-lib-test "$LIB_SH" "$cmd"
}

# lib.sh sources cleanly: no "command not found" and a zero exit status.
test_sources_without_error() {
  local out rc=0
  out="$(_run_lib '' ':' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && ! echo "$out" | grep -q 'command not found'; then
    assert_pass "lib.sh sources without 'command not found'"
  else
    assert_fail "lib-sources" "rc=$rc output: $out"
  fi
}

# NUCLEUS_USER_ROOT is derived to the correct native path for the current OS.
# Source lib.sh directly in this shell so the exported variable is observable
# (avoids embedding $NUCLEUS_USER_ROOT in a single-quoted eval string, which
# trips SC2016 under treefmt's --severity=style shellcheck).
test_nucleus_user_root_resolves() {
  local expected
  # shellcheck disable=SC1090 # reason: dynamic path to lib.sh under test
  . "$LIB_SH"
  case "$(uname -s)" in
  Darwin) expected="$HOME/Library/Application Support/nucleus" ;;
  *) expected="$HOME/.local/share/nucleus" ;;
  esac
  if [ -n "${NUCLEUS_USER_ROOT:-}" ] && [ "$NUCLEUS_USER_ROOT" = "$expected" ]; then
    assert_pass "NUCLEUS_USER_ROOT resolves to native user root"
  else
    assert_fail "user-root" "expected '$expected', got: '${NUCLEUS_USER_ROOT:-}'"
  fi
}

# ---- Run tests ----
section 1 "lib.sh sourcing tests"
echo ""

test_sources_without_error
test_nucleus_user_root_resolves

echo ""
echo "--- lib.sh sourcing tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
