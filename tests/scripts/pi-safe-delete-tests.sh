#!/usr/bin/env bash
# Test: the pi safe-delete extension suite runs under bun and reports real
# passing cases. The wrapper enforces the two failure modes a bare `bun test`
# call would hide in a log: a non-zero exit and a vacuous zero-test run.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command bun "bun test executes the pi safe-delete suite"

_psd_suite="$REPO_ROOT/tests/users/default/pi/extensions/safe-delete-tests.ts"
_psd_out="$(mktemp)"
trap 'rm -f "$_psd_out"' EXIT

if (cd "$REPO_ROOT" && bun test "$_psd_suite") >"$_psd_out" 2>&1; then
  assert_pass "pi safe-delete tests pass under bun test"
else
  assert_fail "pi safe-delete tests pass under bun test" \
    "$(tail -n 20 "$_psd_out" | tr '\n' ' ')"
fi

if grep -qE '(^|[^0-9])[1-9][0-9]* pass' "$_psd_out"; then
  assert_pass "bun reported a non-zero passing test count"
else
  assert_fail "bun reported a non-zero passing test count" \
    "no pass count in: $(tail -n 5 "$_psd_out" | tr '\n' ' ')"
fi

finish_tests
