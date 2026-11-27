#!/usr/bin/env bash
# Test: the Pi agents bridge suite runs under bun and reports real passing
# cases. The wrapper catches a non-zero exit and a vacuous zero-pass run.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command bun "bun test executes the Pi agents bridge suite"

_pab_suite="$REPO_ROOT/tests/users/default/pi/extensions/agents-bridge-tests.ts"
_pab_out="$(mktemp)"
trap 'rm -f "$_pab_out"' EXIT

if (cd "$REPO_ROOT" && bun test "$_pab_suite") >"$_pab_out" 2>&1; then
  assert_pass "Pi agents bridge tests pass under bun test"
else
  assert_fail "Pi agents bridge tests pass under bun test" \
    "$(tail -n 20 "$_pab_out" | tr '\n' ' ')"
fi

if grep -qE '(^|[^0-9])[1-9][0-9]* pass' "$_pab_out"; then
  assert_pass "bun reported a non-zero passing test count"
else
  assert_fail "bun reported a non-zero passing test count" \
    "no non-zero pass count in: $(tail -n 5 "$_pab_out" | tr '\n' ' ')"
fi

finish_tests
