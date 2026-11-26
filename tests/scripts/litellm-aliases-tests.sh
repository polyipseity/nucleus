#!/usr/bin/env bash
# Tests for src/scripts/lib/litellm-aliases.py.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

init_test_state
ensure_safe_rm_env

require_command python3 "litellm-aliases.py is a Python script"
require_command jq "tests assert JSON output with jq"

ALIASES_PY="$REPO_ROOT/src/scripts/lib/litellm-aliases.py"
readonly ALIASES_PY

WORK="$(mktemp -d)"
readonly WORK
# shellcheck disable=SC2064 # reason: WORK is readonly and resolved at trap-install time
trap "rm -rf '$WORK'" EXIT

write_config() {
  local path="$1"
  cat >"$path"
}

run_aliases() {
  local config="$1"
  local out="$2"
  local err="$3"
  set +e
  python3 "$ALIASES_PY" --config "$config" >"$out" 2>"$err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# Case 1: the live config exposes the two aliases present today.
live_out="$WORK/live.out"
live_err="$WORK/live.err"
live_rc="$(run_aliases "$REPO_ROOT/src/modules/configs/litellm/config.yml" "$live_out" "$live_err")"
if [ "$live_rc" -eq 0 ]; then
  assert_pass "live config exits 0"
else
  assert_fail "live config exits 0" "rc=$live_rc stderr=$(cat "$live_err")"
fi

if jq -e '.default.maxInputTokens == 256000 and .default.maxOutputTokens == 16000' "$live_out" >/dev/null 2>&1; then
  assert_pass "live config reports default limits"
else
  assert_fail "live config reports default limits" "$(cat "$live_out")"
fi

if jq -e '."default-free".maxInputTokens == 256000 and ."default-free".maxOutputTokens == 16000' "$live_out" >/dev/null 2>&1; then
  assert_pass "live config reports default-free limits"
else
  assert_fail "live config reports default-free limits" "$(cat "$live_out")"
fi

alias_count="$(jq 'length' "$live_out" 2>/dev/null || echo 0)"
if [ "$alias_count" = "2" ]; then
  assert_pass "live config reports exactly two aliases"
else
  assert_fail "live config reports exactly two aliases" "count=$alias_count output=$(cat "$live_out")"
fi

# Case 2: a commented-only alias is absent.
commented_cfg="$WORK/commented.yml"
write_config "$commented_cfg" <<'YAML'
model_list:
  # - model_name: ghost
  #   litellm_params:
  #     model: openai/ghost
  #     model_info:
  #       max_input_tokens: 1
  #       max_output_tokens: 2
  - model_name: real
    litellm_params:
      model: openai/real
      model_info:
        max_input_tokens: 100
        max_output_tokens: 200
YAML
commented_out="$WORK/commented.out"
commented_err="$WORK/commented.err"
commented_rc="$(run_aliases "$commented_cfg" "$commented_out" "$commented_err")"
if [ "$commented_rc" -eq 0 ] && jq -e '.real.maxInputTokens == 100 and .real.maxOutputTokens == 200 and (has("ghost") | not)' "$commented_out" >/dev/null 2>&1; then
  assert_pass "commented-only alias is absent"
else
  assert_fail "commented-only alias is absent" "rc=$commented_rc out=$(cat "$commented_out") err=$(cat "$commented_err")"
fi

# Case 3: a null-limit alias is represented with JSON nulls.
null_cfg="$WORK/null.yml"
write_config "$null_cfg" <<'YAML'
model_list:
  - model_name: no-limits
    litellm_params:
      model: cline/no-limits
    model_info:
      health_check_max_tokens: 500
  - model_name: partial
    litellm_params:
      model: openai/partial
      model_info:
        max_input_tokens: 4096
YAML
null_out="$WORK/null.out"
null_err="$WORK/null.err"
null_rc="$(run_aliases "$null_cfg" "$null_out" "$null_err")"
if [ "$null_rc" -eq 0 ]; then
  assert_pass "null-limit config exits 0"
else
  assert_fail "null-limit config exits 0" "rc=$null_rc stderr=$(cat "$null_err")"
fi

if jq -e '."no-limits".maxInputTokens == null and ."no-limits".maxOutputTokens == null' "$null_out" >/dev/null 2>&1; then
  assert_pass "alias with no declared limits reports null"
else
  assert_fail "alias with no declared limits reports null" "$(cat "$null_out")"
fi

if jq -e '.partial.maxInputTokens == 4096 and .partial.maxOutputTokens == null' "$null_out" >/dev/null 2>&1; then
  assert_pass "partial limit declaration keeps undeclared field null"
else
  assert_fail "partial limit declaration keeps undeclared field null" "$(cat "$null_out")"
fi

# Case 4: differing numeric non-null limits reconcile to maximum across deployments.
max_cfg="$WORK/max-reconcile.yml"
write_config "$max_cfg" <<'YAML'
model_list:
  - model_name: default
    litellm_params:
      model: openai/a
      model_info:
        max_input_tokens: 256000
        max_output_tokens: 16000
  - model_name: default
    litellm_params:
      model: openai/b
      model_info:
        max_input_tokens: 128000
        max_output_tokens: 32000
YAML
max_out="$WORK/max-reconcile.out"
max_err="$WORK/max-reconcile.err"
max_rc="$(run_aliases "$max_cfg" "$max_out" "$max_err")"
if [ "$max_rc" -eq 0 ] && jq -e '.default.maxInputTokens == 256000 and .default.maxOutputTokens == 32000' "$max_out" >/dev/null 2>&1; then
  assert_pass "differing numeric limits reconcile to maximum"
else
  assert_fail "differing numeric limits reconcile to maximum" "rc=$max_rc err=$(cat "$max_err") out=$(cat "$max_out")"
fi

# Case 4b: conflicting declarations inside one deployment are irreconcilable.
conflict_cfg="$WORK/conflict.yml"
write_config "$conflict_cfg" <<'YAML'
model_list:
  - model_name: default
    litellm_params:
      model: openai/a
      model_info:
        max_input_tokens: 256000
    model_info:
      max_input_tokens: 128000
YAML
conflict_out="$WORK/conflict.out"
conflict_err="$WORK/conflict.err"
conflict_rc="$(run_aliases "$conflict_cfg" "$conflict_out" "$conflict_err")"
if [ "$conflict_rc" -ne 0 ]; then
  assert_pass "in-deployment conflicting limits exit non-zero"
else
  assert_fail "in-deployment conflicting limits exit non-zero" "rc=0 out=$(cat "$conflict_out")"
fi

if grep -Fq "conflicting max_input_tokens values" "$conflict_err" && grep -Fq "default (openai/a)" "$conflict_err"; then
  assert_pass "in-deployment conflicting limits name deployment"
else
  assert_fail "in-deployment conflicting limits name deployment" "$(cat "$conflict_err")"
fi

# Case 5: default config path resolves relative to repo root when --config omitted.
default_rc=0
(
  cd "$REPO_ROOT"
  python3 "$ALIASES_PY" >"$WORK/default-path.out" 2>"$WORK/default-path.err"
) || default_rc=$?
if [ "$default_rc" -eq 0 ] && jq -e '.default and ."default-free"' "$WORK/default-path.out" >/dev/null 2>&1; then
  assert_pass "default config path resolves from repo root"
else
  assert_fail "default config path resolves from repo root" "rc=$default_rc err=$(cat "$WORK/default-path.err") out=$(cat "$WORK/default-path.out")"
fi

finish_tests
