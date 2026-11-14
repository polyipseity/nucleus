#!/usr/bin/env bash
# Test: the pi sandbox-indicator extension suite runs under bun and reports real
# passing cases. The wrapper enforces the two failure modes a bare `bun test`
# call would hide in a log: a non-zero exit and a vacuous zero-pass run.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command bun "bun test executes the pi sandbox-indicator suite"

_psi_suite="./tests/users/default/pi/extensions/sandbox-indicator-tests.ts"
_psi_out="$(mktemp)"
trap 'rm -f "$_psi_out"' EXIT

if (cd "$REPO_ROOT" && bun test "$_psi_suite") >"$_psi_out" 2>&1; then
  assert_pass "pi sandbox-indicator tests pass under bun test"
else
  assert_fail "pi sandbox-indicator tests pass under bun test" \
    "$(tail -n 20 "$_psi_out" | tr '\n' ' ')"
fi

if grep -qE '(^|[^0-9])[1-9][0-9]* pass' "$_psi_out"; then
  assert_pass "bun reported a non-zero passing test count"
else
  assert_fail "bun reported a non-zero passing test count" \
    "no non-zero pass count in: $(tail -n 5 "$_psi_out" | tr '\n' ' ')"
fi

finish_tests
