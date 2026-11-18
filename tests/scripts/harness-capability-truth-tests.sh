#!/usr/bin/env bash
# Fails when a harness advertises a capability it cannot perform, or when a
# prompt file stands in for a real command surface.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
. "$SCRIPT_DIR/test-lib.sh"
init_test_state
matrix="$REPO_ROOT/src/modules/configs/harness-capabilities.json"

# Rule 1: no prompt-file surface can exist, by construction.
legacy="$(jq -r '[.harnesses[].commands[] | select(.surface == "prompt-file")] | length' "$matrix")"
if [ "$legacy" -eq 0 ]; then
  assert_pass "no harness uses a prompt-file surface" ""
else
  assert_fail "no harness uses a prompt-file surface" "$legacy entries"
fi

# Rule 4: every capability is implemented somewhere.
for capability in continue copy-prompt repeat-prompt; do
  count="$(jq --arg c "$capability" '[.harnesses[].commands[] | select(.capability == $c)] | length' "$matrix")"
  if [ "$count" -gt 0 ]; then
    assert_pass "capability $capability is implemented" "$count command(s)"
  else
    assert_fail "capability $capability is implemented" "advertised nowhere"
  fi
done

# Rule 5: no harness repeats a command name.
duplicates="$(jq -r '[.harnesses | to_entries[] | .key as $h | (.value.commands | map(.name) | group_by(.)[] | select(length > 1) | "\($h): \(.[0])")] | .[]' "$matrix")"
if [ -z "$duplicates" ]; then
  assert_pass "no harness repeats a command name" ""
else
  assert_fail "no harness repeats a command name" "$duplicates"
fi

# Rule 2: each name is registered on its own path.
while IFS="$(printf '\t')" read -r harness name path; do
  if rg -q --fixed-strings "$name" "$REPO_ROOT/$path"; then
    assert_pass "$harness registers $name" "$path"
  else
    assert_fail "$harness registers $name" "$path does not name it"
  fi
done < <(jq -r '.harnesses | to_entries[] | .key as $h | .value.commands[] | "\($h)\t\(.name)\t\(.path)"' "$matrix")

# Rule 3: hints list only recorded sources, in either spelling.
if hint_output="$(python3 "$SCRIPT_DIR/harness-capability-truth-hintcheck" "$matrix" "$REPO_ROOT")"; then
  assert_pass "argument hints list only supported sources" ""
else
  assert_fail "argument hints list only supported sources" "$hint_output"
fi

# Rule 6: no prompt file implements a prompt-tools capability.
if planted="$(rg -l "copy-user-prompt|repeat-user-prompt" "$REPO_ROOT/src/users/default/agents/prompts")"; then
  assert_fail "no prompt file implements a prompt-tools command" "$planted"
else
  assert_pass "no prompt file implements a prompt-tools command" ""
fi

finish_tests
