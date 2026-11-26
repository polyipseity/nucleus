#!/usr/bin/env bash
# Tests for the harness-model drift validator and its step-13 wiring.
#
# Every case builds a throwaway repo tree from the live B1, B2, and B3 files,
# then runs the shared Python validator against it. The mutations are the ones
# the drift check exists to catch, so each negative case must fail for its own
# reason rather than for a missing fixture file.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

init_test_state
require_command python3 "the drift validator is a Python script"

VALIDATOR="$REPO_ROOT/src/scripts/lib/harness-model-drift.py"
STEP_SH="$REPO_ROOT/src/scripts/checks/check-steps/13-repo-policy-data.sh"
STEP_PS1="$REPO_ROOT/src/scripts/checks/check-steps/13-repo-policy-data.ps1"
readonly VALIDATOR STEP_SH STEP_PS1

WORK="$(mktemp -d)"
readonly WORK
# shellcheck disable=SC2064 # reason: WORK is readonly and resolved at trap-install time
trap "python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' '$WORK'" EXIT

remove_tree() { # <path>
  python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$1"
}

make_fixture() { # <name>
  local name="$1"
  FIXTURE="$WORK/$name"
  mkdir -p "$FIXTURE/src/modules/configs/litellm" "$FIXTURE/src/scripts/lib" "$FIXTURE/src/scripts/agents"
  cp "$REPO_ROOT/src/modules/configs/litellm/config.yml" "$FIXTURE/src/modules/configs/litellm/config.yml"
  cp "$REPO_ROOT/src/scripts/lib/litellm-aliases.py" "$FIXTURE/src/scripts/lib/litellm-aliases.py"
  cp "$REPO_ROOT/src/scripts/agents/merge-harness-models.py" "$FIXTURE/src/scripts/agents/merge-harness-models.py"
  for file in harness-models.json harness-capabilities.json harness-models.schema.json harness-capabilities.schema.json; do
    cp "$REPO_ROOT/src/modules/configs/$file" "$FIXTURE/src/modules/configs/$file"
  done
  for file in pi/litellm-models.json opencode/litellm-provider.json claude/litellm-env.json \
    vscode/litellm-entry.json vscode/chatLanguageModels.MacBook.json \
    vscode/chatLanguageModels.NixOS.json vscode/chatLanguageModels.Windows.json \
    copilot/litellm-providers.json hermes/litellm-config.yaml codex/litellm-config.toml; do
    mkdir -p "$FIXTURE/src/users/default/$(dirname "$file")"
    cp "$REPO_ROOT/src/users/default/$file" "$FIXTURE/src/users/default/$file"
  done
}

mutate_json() { # <path> <python-expression>
  python3 - "$1" "$2" <<'PY'
import json
import sys
path, expression = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
exec(expression, {"data": data})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

run_validator() { # <fixture> <out-file> [extra args...]
  local fixture="$1" out="$2"
  shift 2
  local rc=0
  python3 "$VALIDATOR" --repo-root "$fixture" "$@" >"$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

test_live_payloads_pass_and_are_not_mutated() {
  make_fixture pass
  local out="$WORK/pass.out"
  local before after rc
  before="$(find "$FIXTURE/src" -type f -exec sh -c 'shasum "$1" | cut -d " " -f 1' _ {} \; | sort)"
  rc="$(run_validator "$FIXTURE" "$out")"
  after="$(find "$FIXTURE/src" -type f -exec sh -c 'shasum "$1" | cut -d " " -f 1' _ {} \; | sort)"
  if [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; then
    assert_pass "the live payload set passes and the validator leaves the repo untouched"
  else
    assert_fail "the live payload set passes and the validator leaves the repo untouched" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_missing_alias_fails() {
  make_fixture missing
  mutate_json "$FIXTURE/src/users/default/pi/litellm-models.json" \
    "data['models'] = [m for m in data['models'] if m['id'] != 'default-free']"
  local out="$WORK/missing.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q 'pi: missing aliases: default-free' "$out"; then
    assert_pass "a missing alias fails and names it"
  else
    assert_fail "a missing alias fails and names it" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_extra_alias_fails() {
  make_fixture extra
  mutate_json "$FIXTURE/src/users/default/opencode/litellm-provider.json" \
    "data['models']['stray'] = {'maxInputTokens': 256000, 'maxOutputTokens': 16000}"
  local out="$WORK/extra.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q 'opencode: extra aliases: stray' "$out"; then
    assert_pass "an extra alias fails and names it"
  else
    assert_fail "an extra alias fails and names it" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_wrong_token_limit_fails() {
  make_fixture limit
  mutate_json "$FIXTURE/src/users/default/copilot/litellm-providers.json" \
    "data['models']['default']['maxInputTokens'] = 1"
  local out="$WORK/limit.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q 'copilot: default: maxInputTokens expected 256000, got 1' "$out"; then
    assert_pass "a wrong token limit fails and names the value"
  else
    assert_fail "a wrong token limit fails and names the value" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_null_vs_declared_limit_fails() {
  make_fixture null
  python3 - "$FIXTURE/src/modules/configs/litellm/config.yml" <<'PY'
import sys
import yaml
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
for deployment in data["model_list"]:
    containers = [deployment.get("model_info")]
    params = deployment.get("litellm_params")
    if isinstance(params, dict):
        containers.append(params.get("model_info"))
    for info in containers:
        if isinstance(info, dict):
            info.pop("max_output_tokens", None)
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=False)
PY
  local out="$WORK/null.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q 'null in B1' "$out"; then
    assert_pass "a payload limit declared where B1 is null fails"
  else
    assert_fail "a payload limit declared where B1 is null fails" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_divergent_vscode_host_entry_fails() {
  make_fixture vscode
  mutate_json "$FIXTURE/src/users/default/vscode/chatLanguageModels.MacBook.json" \
    "data[0]['models'] = data[0]['models'][:1]"
  local out="$WORK/vscode.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q 'vscode:MacBook: LiteLLM entry differs from canonical payload' "$out"; then
    assert_pass "one divergent VS Code host entry fails"
  else
    assert_fail "one divergent VS Code host entry fails" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_vscode_suffixed_live_path_fails() {
  make_fixture vscode-basename
  mutate_json "$FIXTURE/src/modules/configs/harness-models.json" \
    "next(h for h in data['harnesses'] if h['harness'] == 'vscode')['path']['MacBook'] = '~/Library/Application Support/Code/User/chatLanguageModels.MacBook.json'"
  local out="$WORK/vscode-basename.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q 'vscode:MacBook: registry path basename must be chatLanguageModels.json' "$out"; then
    assert_pass "a suffixed VS Code live registry path fails"
  else
    assert_fail "a suffixed VS Code live registry path fails" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_claude_stale_pin_fails() {
  make_fixture claude
  mutate_json "$FIXTURE/src/users/default/claude/litellm-env.json" \
    "data['ANTHROPIC_MODEL'] = 'stale-id'"
  local out="$WORK/claude.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q "claude: pinned model 'stale-id' is not a B1 alias" "$out"; then
    assert_pass "a stale Claude pinned model fails"
  else
    assert_fail "a stale Claude pinned model fails" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_codex_stale_pin_fails() {
  make_fixture codex
  python3 - "$FIXTURE/src/users/default/codex/litellm-config.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace('model = "default"', 'model = "stale-id"')
open(path, "w", encoding="utf-8").write(text)
PY
  local out="$WORK/codex.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q "codex: pinned model 'stale-id' is not a B1 alias" "$out"; then
    assert_pass "a stale Codex pinned model fails"
  else
    assert_fail "a stale Codex pinned model fails" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_registry_id_missing_from_capabilities_fails() {
  make_fixture registry
  mutate_json "$FIXTURE/src/modules/configs/harness-capabilities.json" \
    "del data['harnesses']['pi']"
  local out="$WORK/registry.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q "registry: model harness 'pi' missing from capabilities" "$out"; then
    assert_pass "a model harness missing from capabilities fails"
  else
    assert_fail "a model harness missing from capabilities fails" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_prompt_capability_without_payload_fails() {
  make_fixture capability
  mutate_json "$FIXTURE/src/modules/configs/harness-capabilities.json" \
    "data['harnesses']['ghost'] = {'commands': [{'name': 'continue', 'capability': 'continue', 'surface': 'mod', 'picker': 'none', 'sources': [], 'path': 'src/ghost.js'}]}"
  local out="$WORK/capability.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q "capabilities: harness 'ghost' declares prompt commands but has no model payload" "$out"; then
    assert_pass "a command-capable harness without a model payload fails"
  else
    assert_fail "a command-capable harness without a model payload fails" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_merge_drift_fails() {
  make_fixture drift
  cp "$FIXTURE/src/users/default/pi/litellm-models.json" "$FIXTURE/src/users/default/pi/litellm-models-second.json"
  mutate_json "$FIXTURE/src/users/default/pi/litellm-models-second.json" \
    "data['baseUrl'] = 'http://127.0.0.1:4001/v1'"
  mutate_json "$FIXTURE/src/modules/configs/harness-models.json" \
    "data['harnesses'].append(dict(data['harnesses'][0], payload='src/users/default/pi/litellm-models-second.json'))"
  local out="$WORK/drift.out"
  local rc
  rc="$(run_validator "$FIXTURE" "$out")"
  if [ "$rc" -ne 0 ] && grep -q 'merge --check failed' "$out"; then
    assert_pass "a live slot that diverges from its payload fails the merge proof"
  else
    assert_fail "a live slot that diverges from its payload fails the merge proof" "rc=$rc output=[$(cat "$out")]"
  fi
  remove_tree "$FIXTURE"
}

test_both_steps_declare_the_validator() {
  local out rc=0
  out="$(
    python3 - "$STEP_SH" "$STEP_PS1" <<'PY'
import sys
sh, ps1 = (open(path, encoding="utf-8").read() for path in sys.argv[1:])
checks = {
  "POSIX registration": 'harness model drift|run_harness_model_drift|ctx' in sh,
  "POSIX python tool": 'register_step_tools "repo-policy-data" "bun git jq nix python3"' in sh,
  "PowerShell section": "--- harness model drift ---" in ps1,
  "PowerShell python tool": 'Register-StepToolManifest -Id "repo-policy-data" -Tool "git python3"' in ps1,
}
for name, ok in checks.items():
    if not ok:
        print(name)
PY
  )"
  if [ -z "$out" ]; then
    assert_pass "both step twins wire the validator and declare python3"
  else
    assert_fail "both step twins wire the validator and declare python3" "$out"
  fi
}

section 1 "the live payload set"
test_live_payloads_pass_and_are_not_mutated

section 2 "payload drift"
test_missing_alias_fails
test_extra_alias_fails
test_wrong_token_limit_fails
test_null_vs_declared_limit_fails
test_divergent_vscode_host_entry_fails
test_vscode_suffixed_live_path_fails
test_claude_stale_pin_fails
test_codex_stale_pin_fails

section 3 "registry drift"
test_registry_id_missing_from_capabilities_fails
test_prompt_capability_without_payload_fails

section 4 "merge proof and wiring"
test_merge_drift_fails
test_both_steps_declare_the_validator

finish_tests
