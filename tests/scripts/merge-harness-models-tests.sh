#!/usr/bin/env bash
# Tests for src/scripts/agents/merge-harness-models.py (Task B2).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

init_test_state
ensure_safe_rm_env

require_command python3 "merge-harness-models.py is a Python script"

MERGE_PY="$REPO_ROOT/src/scripts/agents/merge-harness-models.py"
readonly MERGE_PY

WORK="$(mktemp -d)"
readonly WORK
# shellcheck disable=SC2064 # reason: WORK is readonly and resolved at trap-install time
trap "rm -rf '$WORK'" EXIT

json_get() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
cur = data
for part in expr.split('.'):
    if part == '':
        continue
    if isinstance(cur, list):
        cur = cur[int(part)]
    else:
        cur = cur[part]
print(json.dumps(cur, sort_keys=True))
PY
}

run_merge() {
  local registry="$1"
  local home_dir="$2"
  local out="$3"
  local err="$4"
  shift 4
  set +e
  python3 "$MERGE_PY" --registry "$registry" --home "$home_dir" --repo-root "$REPO_ROOT" "$@" >"$out" 2>"$err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# ---- JSON format -----------------------------------------------------------

json_home="$WORK/json-home"
json_registry="$WORK/json-registry.json"
json_payload="$WORK/json-payload.json"
json_target="$json_home/.config/harness/config.json"
mkdir -p "$(dirname "$json_target")"

cat >"$json_payload" <<'JSON'
{
  "baseUrl": "http://127.0.0.1:4000/v1",
  "models": {
    "default": {
      "maxInputTokens": 256000,
      "maxOutputTokens": 16000
    }
  }
}
JSON

cat >"$json_registry" <<'JSON'
{
  "$schema": "../../src/modules/configs/harness-models.schema.json",
  "version": 1,
  "harnesses": [
    {
      "harness": "json-harness",
      "path": "~/.config/harness/config.json",
      "format": "json",
      "slot": { "kind": "dotted-key", "path": "providers.litellm" },
      "payload": "tests/fixtures/does-not-matter.json"
    }
  ]
}
JSON

python3 - "$json_registry" "$json_payload" <<'PY'
import json, sys
reg, payload = sys.argv[1], sys.argv[2]
d = json.load(open(reg))
d['harnesses'][0]['payload'] = payload
json.dump(d, open(reg, 'w'))
PY

json_out="$WORK/json.out"
json_err="$WORK/json.err"
json_rc="$(run_merge "$json_registry" "$json_home" "$json_out" "$json_err")"
if [ "$json_rc" -eq 0 ] && [ -f "$json_target" ]; then
  assert_pass "json: missing file is created"
else
  assert_fail "json: missing file is created" "rc=$json_rc err=$(cat "$json_err")"
fi

if [ "$(json_get "$json_target" 'providers.litellm.baseUrl')" = '"http://127.0.0.1:4000/v1"' ]; then
  assert_pass "json: created file contains payload"
else
  assert_fail "json: created file contains payload" "$(cat "$json_target")"
fi

cp "$json_target" "$WORK/json.before"
json_rc="$(run_merge "$json_registry" "$json_home" "$json_out" "$json_err")"
if [ "$json_rc" -eq 0 ] && cmp -s "$WORK/json.before" "$json_target"; then
  assert_pass "json: second run is idempotent"
else
  assert_fail "json: second run is idempotent" "rc=$json_rc err=$(cat "$json_err")"
fi

python3 - "$json_target" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['providers']['litellm']['models']['default']['maxInputTokens'] = 999
json.dump(d, open(p, 'w'), indent=2)
open(p, 'a').write('\n')
PY
json_rc="$(run_merge "$json_registry" "$json_home" "$json_out" "$json_err" --check)"
if [ "$json_rc" -ne 0 ] && grep -q "drift" "$json_out"; then
  assert_pass "json: --check detects one-token drift"
else
  assert_fail "json: --check detects one-token drift" "rc=$json_rc out=$(cat "$json_out") err=$(cat "$json_err")"
fi

cat >"$json_target" <<'JSON'
{
  "unrelated": {
    "keep": "yes",
    "list": [1, 2, 3]
  },
  "providers": {
    "other": {
      "untouched": true
    },
    "litellm": {
      "baseUrl": "http://old",
      "models": {}
    }
  },
  "tail": "keep-me"
}
JSON
json_rc="$(run_merge "$json_registry" "$json_home" "$json_out" "$json_err")"
if [ "$json_rc" -ne 0 ]; then
  assert_fail "json: merge with unrelated keys exits 0" "rc=$json_rc err=$(cat "$json_err")"
else
  assert_pass "json: merge with unrelated keys exits 0"
fi

if [ "$(json_get "$json_target" 'unrelated.keep')" = '"yes"' ] &&
  [ "$(json_get "$json_target" 'providers.other.untouched')" = 'true' ] &&
  [ "$(json_get "$json_target" 'tail')" = '"keep-me"' ]; then
  assert_pass "json: unrelated keys survive merge"
else
  assert_fail "json: unrelated keys survive merge" "$(cat "$json_target")"
fi

cat >"$json_target" <<'BAD'
{ "providers": { "litellm": [ }
BAD
cp "$json_target" "$WORK/json.corrupt.before"
json_rc="$(run_merge "$json_registry" "$json_home" "$json_out" "$json_err")"
if [ "$json_rc" -ne 0 ] && cmp -s "$WORK/json.corrupt.before" "$json_target"; then
  assert_pass "json: corrupt file errors and is not overwritten"
else
  assert_fail "json: corrupt file errors and is not overwritten" "rc=$json_rc changed=$(cmp -s "$WORK/json.corrupt.before" "$json_target" && echo no || echo yes) err=$(cat "$json_err")"
fi
if grep -Eq 'line|column|parse|invalid JSON' "$json_err"; then
  assert_pass "json: corrupt file error names parse position"
else
  assert_fail "json: corrupt file error names parse position" "$(cat "$json_err")"
fi

# ---- JSONC format ----------------------------------------------------------

jsonc_home="$WORK/jsonc-home"
jsonc_registry="$WORK/jsonc-registry.json"
jsonc_payload="$WORK/jsonc-payload.json"
jsonc_target="$jsonc_home/.config/opencode/opencode.jsonc"
mkdir -p "$(dirname "$jsonc_target")"

cat >"$jsonc_payload" <<'JSON'
{
  "npm": "@ai-sdk/openai-compatible",
  "options": {
    "baseURL": "http://127.0.0.1:4000/v1"
  }
}
JSON

cat >"$jsonc_registry" <<'JSON'
{
  "version": 1,
  "harnesses": [
    {
      "harness": "jsonc-harness",
      "path": "~/.config/opencode/opencode.jsonc",
      "format": "jsonc",
      "slot": { "kind": "dotted-key", "path": "provider.litellm" },
      "payload": "IGNORED"
    }
  ]
}
JSON
python3 - "$jsonc_registry" "$jsonc_payload" <<'PY'
import json, sys
reg, payload = sys.argv[1], sys.argv[2]
d = json.load(open(reg))
d['harnesses'][0]['payload'] = payload
json.dump(d, open(reg, 'w'))
PY

cat >"$jsonc_target" <<'JSONC'
{
  // top comment should survive
  "provider": {
    "other": {
      "keep": true
    },
    "litellm": {
      // old value comment inside owned value may change; outside must survive
      "options": {
        "baseURL": "http://old"
      }
    }
  },
  // tail comment should survive
  "ui": {
    "theme": "dark"
  }
}
JSONC

jsonc_out="$WORK/jsonc.out"
jsonc_err="$WORK/jsonc.err"
jsonc_rc="$(run_merge "$jsonc_registry" "$jsonc_home" "$jsonc_out" "$jsonc_err")"
if [ "$jsonc_rc" -eq 0 ]; then
  assert_pass "jsonc: merge exits 0"
else
  assert_fail "jsonc: merge exits 0" "rc=$jsonc_rc err=$(cat "$jsonc_err")"
fi

if grep -q "// top comment should survive" "$jsonc_target" &&
  grep -q "// tail comment should survive" "$jsonc_target" &&
  grep -q '"theme": "dark"' "$jsonc_target"; then
  assert_pass "jsonc: comments and unrelated keys survive merge"
else
  assert_fail "jsonc: comments and unrelated keys survive merge" "$(cat "$jsonc_target")"
fi

if grep -q '"baseURL": "http://127.0.0.1:4000/v1"' "$jsonc_target"; then
  assert_pass "jsonc: owned slot value replaced"
else
  assert_fail "jsonc: owned slot value replaced" "$(cat "$jsonc_target")"
fi

cp "$jsonc_target" "$WORK/jsonc.before"
jsonc_rc="$(run_merge "$jsonc_registry" "$jsonc_home" "$jsonc_out" "$jsonc_err")"
if [ "$jsonc_rc" -eq 0 ] && cmp -s "$WORK/jsonc.before" "$jsonc_target"; then
  assert_pass "jsonc: second run is idempotent"
else
  assert_fail "jsonc: second run is idempotent" "rc=$jsonc_rc err=$(cat "$jsonc_err")"
fi

cat >"$jsonc_target" <<'JSONC'
{
  "provider": {
    "litellm": { broken
  }
}
JSONC
cp "$jsonc_target" "$WORK/jsonc.corrupt.before"
jsonc_rc="$(run_merge "$jsonc_registry" "$jsonc_home" "$jsonc_out" "$jsonc_err")"
if [ "$jsonc_rc" -ne 0 ] && cmp -s "$WORK/jsonc.corrupt.before" "$jsonc_target"; then
  assert_pass "jsonc: corrupt file errors and is not overwritten"
else
  assert_fail "jsonc: corrupt file errors and is not overwritten" "rc=$jsonc_rc changed=$(cmp -s "$WORK/jsonc.corrupt.before" "$jsonc_target" && echo no || echo yes) err=$(cat "$jsonc_err")"
fi

# ---- YAML format -----------------------------------------------------------

yaml_home="$WORK/yaml-home"
yaml_registry="$WORK/yaml-registry.json"
yaml_payload="$WORK/yaml-payload.yaml"
yaml_target="$yaml_home/.hermes/config.yaml"
mkdir -p "$(dirname "$yaml_target")"

cat >"$yaml_payload" <<'YAML'
name: litellm
base_url: http://127.0.0.1:4000/v1
models:
  - default
  - default-free
YAML

cat >"$yaml_registry" <<'JSON'
{
  "version": 1,
  "harnesses": [
    {
      "harness": "yaml-harness",
      "path": "~/.hermes/config.yaml",
      "format": "yaml",
      "slot": {
        "kind": "yaml-named-item",
        "listKey": "custom_providers",
        "itemKey": "name",
        "itemName": "litellm"
      },
      "payload": "IGNORED"
    }
  ]
}
JSON
python3 - "$yaml_registry" "$yaml_payload" <<'PY'
import json, sys
reg, payload = sys.argv[1], sys.argv[2]
d = json.load(open(reg))
d['harnesses'][0]['payload'] = payload
json.dump(d, open(reg, 'w'))
PY

cat >"$yaml_target" <<'YAML'
# top-level comment
custom_providers:
  - name: other-provider
    base_url: https://example.invalid
    # keep this comment
  - name: litellm
    base_url: http://old
    models:
      - stale
other_key: keep-me
YAML

yaml_out="$WORK/yaml.out"
yaml_err="$WORK/yaml.err"
yaml_rc="$(run_merge "$yaml_registry" "$yaml_home" "$yaml_out" "$yaml_err")"
if [ "$yaml_rc" -eq 0 ]; then
  assert_pass "yaml: merge exits 0"
else
  assert_fail "yaml: merge exits 0" "rc=$yaml_rc err=$(cat "$yaml_err")"
fi

if grep -q "other-provider" "$yaml_target" &&
  grep -q "other_key: keep-me" "$yaml_target" &&
  grep -q "# keep this comment" "$yaml_target"; then
  assert_pass "yaml: unrelated list item, comment, and key survive merge"
else
  assert_fail "yaml: unrelated list item, comment, and key survive merge" "$(cat "$yaml_target")"
fi

if grep -q "base_url: http://127.0.0.1:4000/v1" "$yaml_target" &&
  grep -q "default-free" "$yaml_target"; then
  assert_pass "yaml: owned list item replaced"
else
  assert_fail "yaml: owned list item replaced" "$(cat "$yaml_target")"
fi

cp "$yaml_target" "$WORK/yaml.before"
yaml_rc="$(run_merge "$yaml_registry" "$yaml_home" "$yaml_out" "$yaml_err")"
if [ "$yaml_rc" -eq 0 ] && cmp -s "$WORK/yaml.before" "$yaml_target"; then
  assert_pass "yaml: second run is idempotent"
else
  assert_fail "yaml: second run is idempotent" "rc=$yaml_rc err=$(cat "$yaml_err")"
fi

python3 - "$yaml_target" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read().replace('default-free', 'drifted')
open(p, 'w').write(text)
PY
yaml_rc="$(run_merge "$yaml_registry" "$yaml_home" "$yaml_out" "$yaml_err" --check)"
if [ "$yaml_rc" -ne 0 ] && grep -q "drift" "$yaml_out"; then
  assert_pass "yaml: --check detects one-token drift"
else
  assert_fail "yaml: --check detects one-token drift" "rc=$yaml_rc out=$(cat "$yaml_out") err=$(cat "$yaml_err")"
fi

cat >"$yaml_target" <<'YAML'
custom_providers:
  - name: litellm
    base_url: [unterminated
YAML
cp "$yaml_target" "$WORK/yaml.corrupt.before"
yaml_rc="$(run_merge "$yaml_registry" "$yaml_home" "$yaml_out" "$yaml_err")"
if [ "$yaml_rc" -ne 0 ] && cmp -s "$WORK/yaml.corrupt.before" "$yaml_target"; then
  assert_pass "yaml: corrupt file errors and is not overwritten"
else
  assert_fail "yaml: corrupt file errors and is not overwritten" "rc=$yaml_rc changed=$(cmp -s "$WORK/yaml.corrupt.before" "$yaml_target" && echo no || echo yes) err=$(cat "$yaml_err")"
fi

# ---- TOML format -----------------------------------------------------------

toml_home="$WORK/toml-home"
toml_registry="$WORK/toml-registry.json"
toml_payload="$WORK/toml-payload.toml"
toml_target="$toml_home/.codex/config.toml"
mkdir -p "$(dirname "$toml_target")"

cat >"$toml_payload" <<'TOML'
model_provider = "litellm"

[model_providers.litellm]
name = "litellm"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"
TOML

cat >"$toml_registry" <<'JSON'
{
  "version": 1,
  "harnesses": [
    {
      "harness": "toml-harness",
      "path": "~/.codex/config.toml",
      "format": "toml",
      "slot": {
        "kind": "toml-provider-table",
        "topLevelKey": "model_provider",
        "table": "model_providers.litellm"
      },
      "payload": "IGNORED"
    }
  ]
}
JSON
python3 - "$toml_registry" "$toml_payload" <<'PY'
import json, sys
reg, payload = sys.argv[1], sys.argv[2]
d = json.load(open(reg))
d['harnesses'][0]['payload'] = payload
json.dump(d, open(reg, 'w'))
PY

cat >"$toml_target" <<'TOML'
# top comment
model = "old-model"
model_provider = "old-provider"

[profile.dev]
model = "keep-me"

[model_providers.litellm]
name = "litellm"
base_url = "http://old"
wire_api = "responses"

[other.section]
keep = true
TOML

toml_out="$WORK/toml.out"
toml_err="$WORK/toml.err"
toml_rc="$(run_merge "$toml_registry" "$toml_home" "$toml_out" "$toml_err")"
if [ "$toml_rc" -eq 0 ]; then
  assert_pass "toml: merge exits 0"
else
  assert_fail "toml: merge exits 0" "rc=$toml_rc err=$(cat "$toml_err")"
fi

if grep -q '# top comment' "$toml_target" &&
  grep -q '\[profile.dev\]' "$toml_target" &&
  grep -q 'model = "keep-me"' "$toml_target" &&
  grep -q '\[other.section\]' "$toml_target" &&
  grep -q 'keep = true' "$toml_target"; then
  assert_pass "toml: unrelated comments/sections survive merge"
else
  assert_fail "toml: unrelated comments/sections survive merge" "$(cat "$toml_target")"
fi

if grep -q 'model_provider = "litellm"' "$toml_target" &&
  grep -q 'base_url = "http://127.0.0.1:4000/v1"' "$toml_target"; then
  assert_pass "toml: owned key and table replaced"
else
  assert_fail "toml: owned key and table replaced" "$(cat "$toml_target")"
fi

cp "$toml_target" "$WORK/toml.before"
toml_rc="$(run_merge "$toml_registry" "$toml_home" "$toml_out" "$toml_err")"
if [ "$toml_rc" -eq 0 ] && cmp -s "$WORK/toml.before" "$toml_target"; then
  assert_pass "toml: second run is idempotent"
else
  assert_fail "toml: second run is idempotent" "rc=$toml_rc err=$(cat "$toml_err")"
fi

python3 - "$toml_target" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read().replace('127.0.0.1:4000', '127.0.0.1:9999')
open(p, 'w').write(text)
PY
toml_rc="$(run_merge "$toml_registry" "$toml_home" "$toml_out" "$toml_err" --check)"
if [ "$toml_rc" -ne 0 ] && grep -q "drift" "$toml_out"; then
  assert_pass "toml: --check detects one-token drift"
else
  assert_fail "toml: --check detects one-token drift" "rc=$toml_rc out=$(cat "$toml_out") err=$(cat "$toml_err")"
fi

cat >"$toml_target" <<'TOML'
model_provider = "litellm"
[model_providers.litellm
name = "broken"
TOML
cp "$toml_target" "$WORK/toml.corrupt.before"
toml_rc="$(run_merge "$toml_registry" "$toml_home" "$toml_out" "$toml_err")"
if [ "$toml_rc" -ne 0 ] && cmp -s "$WORK/toml.corrupt.before" "$toml_target"; then
  assert_pass "toml: corrupt/unparseable file errors and is not overwritten"
else
  assert_fail "toml: corrupt/unparseable file errors and is not overwritten" "rc=$toml_rc changed=$(cmp -s "$WORK/toml.corrupt.before" "$toml_target" && echo no || echo yes) err=$(cat "$toml_err")"
fi

# ---- named-array-item (VS Code style) -------------------------------------

arr_home="$WORK/arr-home"
arr_registry="$WORK/arr-registry.json"
arr_payload="$WORK/arr-payload.json"
arr_target="$arr_home/.config/Code/User/chatLanguageModels.json"
mkdir -p "$(dirname "$arr_target")"

cat >"$arr_payload" <<'JSON'
{
  "name": "LiteLLM",
  "vendor": "litellm",
  "models": [
    { "id": "default" }
  ]
}
JSON

cat >"$arr_registry" <<JSON
{
  "\$schema": "../../src/modules/configs/harness-models.schema.json",
  "version": 1,
  "harnesses": [
    {
      "harness": "vscode",
      "path": "~/.config/Code/User/chatLanguageModels.json",
      "format": "json",
      "slot": {
        "kind": "named-array-item",
        "arrayPath": "\$",
        "matchKey": "name",
        "matchValue": "LiteLLM"
      },
      "payload": "$arr_payload"
    }
  ]
}
JSON

cat >"$arr_target" <<'JSON'
[
  {
    "name": "Other",
    "vendor": "other",
    "models": [
      { "id": "keep" }
    ]
  },
  {
    "name": "LiteLLM",
    "vendor": "old",
    "models": []
  }
]
JSON

arr_out="$WORK/arr.out"
arr_err="$WORK/arr.err"
arr_rc="$(run_merge "$arr_registry" "$arr_home" "$arr_out" "$arr_err")"
if [ "$arr_rc" -eq 0 ] && grep -q '"vendor": "other"' "$arr_target" && grep -q '"vendor": "litellm"' "$arr_target"; then
  assert_pass "json: named-array-item replaces owned item and keeps others"
else
  assert_fail "json: named-array-item replaces owned item and keeps others" "rc=$arr_rc err=$(cat "$arr_err") target=$(cat "$arr_target")"
fi

cp "$arr_target" "$WORK/arr.before"
arr_rc="$(run_merge "$arr_registry" "$arr_home" "$arr_out" "$arr_err")"
if [ "$arr_rc" -eq 0 ] && cmp -s "$WORK/arr.before" "$arr_target"; then
  assert_pass "json: named-array-item second run is idempotent"
else
  assert_fail "json: named-array-item second run is idempotent" "rc=$arr_rc err=$(cat "$arr_err")"
fi

python3 - "$arr_target" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
for item in d:
  if item.get('name')=='LiteLLM':
    item['vendor']='drift'
json.dump(d, open(p,'w'), indent=2)
open(p,'a').write('\n')
PY
arr_rc="$(run_merge "$arr_registry" "$arr_home" "$arr_out" "$arr_err" --check)"
if [ "$arr_rc" -ne 0 ] && grep -q drift "$arr_out"; then
  assert_pass "json: named-array-item --check detects drift"
else
  assert_fail "json: named-array-item --check detects drift" "rc=$arr_rc out=$(cat "$arr_out") err=$(cat "$arr_err")"
fi

# ---- missing target created (YAML/TOML) ------------------------------------

yaml_missing_home="$WORK/yaml-missing-home"
yaml_missing_target="$yaml_missing_home/.hermes/config.yaml"
yaml_rc="$(run_merge "$yaml_registry" "$yaml_missing_home" "$yaml_out" "$yaml_err")"
if [ "$yaml_rc" -eq 0 ] && [ -f "$yaml_missing_target" ] && grep -q "default-free" "$yaml_missing_target"; then
  assert_pass "yaml: missing file is created"
else
  assert_fail "yaml: missing file is created" "rc=$yaml_rc err=$(cat "$yaml_err")"
fi

toml_missing_home="$WORK/toml-missing-home"
toml_missing_target="$toml_missing_home/.codex/config.toml"
toml_rc="$(run_merge "$toml_registry" "$toml_missing_home" "$toml_out" "$toml_err")"
if [ "$toml_rc" -eq 0 ] && [ -f "$toml_missing_target" ] && grep -q 'model_provider = "litellm"' "$toml_missing_target"; then
  assert_pass "toml: missing file is created"
else
  assert_fail "toml: missing file is created" "rc=$toml_rc err=$(cat "$toml_err")"
fi

finish_tests
