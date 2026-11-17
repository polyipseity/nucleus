#!/usr/bin/env bash
# D2: vm list/status --json parse and state field correctness.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "vm JSON tests require jq"

VM_SH="$REPO_ROOT/scripts/vm.sh"

section 1 "list/status JSON parse and state is running|stopped"

list_json="$("$VM_SH" list --json)"
if printf '%s' "$list_json" | jq -e 'type == "array"' >/dev/null; then
  assert_pass "vm list --json parses as array"
else
  assert_fail "vm list --json parses as array" "invalid JSON"
fi

status_json="$("$VM_SH" status --json)"
if printf '%s' "$status_json" | jq -e 'type == "array"' >/dev/null; then
  assert_pass "vm status --json parses as array"
else
  assert_fail "vm status --json parses as array" "invalid JSON"
fi

if printf '%s' "$list_json" | jq -e '[.[] | (.state == "running" or .state == "stopped")] | all' >/dev/null; then
  assert_pass "vm list --json entries have state running|stopped"
else
  assert_fail "vm list --json entries have state running|stopped" "$(printf '%s' "$list_json" | jq -c '.' | head -c 300)"
fi

if printf '%s' "$status_json" | jq -e '[.[] | (.state == "running" or .state == "stopped")] | all' >/dev/null; then
  assert_pass "vm status --json entries have state running|stopped"
else
  assert_fail "vm status --json entries have state running|stopped" "$(printf '%s' "$status_json" | jq -c '.' | head -c 300)"
fi

if printf '%s' "$list_json" | jq -e '(length == 0) or (.[0] | has("id") and has("name"))' >/dev/null; then
  assert_pass "vm list --json entries preserve id/name fields when present"
else
  assert_fail "vm list --json entries preserve id/name fields when present" "missing expected fields"
fi

finish_tests
