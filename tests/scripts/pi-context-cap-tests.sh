#!/usr/bin/env bash
# Test: the pi context-cap precedence suite runs under bun and reports real
# passing cases. The wrapper enforces the two failure modes a bare `bun test`
# call would hide in a log: a non-zero exit and a vacuous zero-test run.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command bun "bun test executes the context-cap precedence suite"

_pcc_suite="$REPO_ROOT/tests/users/default/pi/extensions/context-cap-tests.ts"
_pcc_out="$(mktemp)"
trap 'rm -f "$_pcc_out"' EXIT

if bun test "$_pcc_suite" >"$_pcc_out" 2>&1; then
  assert_pass "context-cap precedence tests pass under bun test"
else
  assert_fail "context-cap precedence tests pass under bun test" \
    "$(tail -n 20 "$_pcc_out" | tr '\n' ' ')"
fi

if grep -qE '(^|[^0-9])[1-9][0-9]* pass' "$_pcc_out"; then
  assert_pass "bun reported a non-zero passing test count"
else
  assert_fail "bun reported a non-zero passing test count" \
    "no pass count in: $(tail -n 5 "$_pcc_out" | tr '\n' ' ')"
fi

finish_tests
