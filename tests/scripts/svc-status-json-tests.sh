#!/usr/bin/env bash
# D1: svc status/list JSON typing and resilience of listing output.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "svc status JSON tests require jq"

SVC_SH="$REPO_ROOT/scripts/svc.sh"

section 1 "list --json and status --json parse with typed fields"

list_json="$("$SVC_SH" list --json)"
if printf '%s' "$list_json" | jq -e '.version == 1 and (.services | type == "object")' >/dev/null; then
  assert_pass "list --json parses and has version/services object"
else
  assert_fail "list --json parses and has version/services object" "invalid JSON shape"
fi

status_json="$("$SVC_SH" status --json)"
if printf '%s' "$status_json" | jq -e '.version == 1 and (.services | type == "object")' >/dev/null; then
  assert_pass "status --json parses and has version/services object"
else
  assert_fail "status --json parses and has version/services object" "invalid JSON shape"
fi

if printf '%s' "$list_json" | jq -e '[.services[] |
  (.running | type == "boolean") and
  (.status | type == "string") and
  (.exitCode == null or (.exitCode | type == "number")) and
  (.state == null or (.state | type == "string"))
] | all' >/dev/null; then
  assert_pass "list --json service fields have expected types"
else
  assert_fail "list --json service fields have expected types" "$(printf '%s' "$list_json" | jq -c '.services' | head -c 300)"
fi

if printf '%s' "$status_json" | jq -e '[.services[] |
  (.running | type == "boolean") and
  (.status | type == "string") and
  (.exitCode == null or (.exitCode | type == "number")) and
  (.state == null or (.state | type == "string"))
] | all' >/dev/null; then
  assert_pass "status --json service fields have expected types"
else
  assert_fail "status --json service fields have expected types" "$(printf '%s' "$status_json" | jq -c '.services' | head -c 300)"
fi

section 2 "text listing prints every service reported by JSON"

list_text="$("$SVC_SH" list)"
missing=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if ! printf '%s\n' "$list_text" | grep -Fq "$id"; then
    assert_fail "text list contains service id: $id" "not found in text output"
    missing=1
  fi
done < <(printf '%s' "$list_json" | jq -r '.services | keys[]')
if [ "$missing" -eq 0 ]; then
  assert_pass "text list contains every service id from list --json"
fi

finish_tests
