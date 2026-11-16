#!/usr/bin/env bash
# Tests for the provisioned-tools instruction drift sub-check
# (run_provisioned_tools_instruction_drift, step 13).
#
# The sub-check derives required CLI tool names from src/modules/core.nix
# (managedPackages category=cli, excluding fonts and the dummy default marker)
# and from every package name in src/modules/packages/desired.json, then fails
# when a required backticked name is missing from the nucleus provisioned tools
# instruction. These cases drive the real function through the real check-lib
# against a throwaway repo.
#
# Run with: bash tests/scripts/check-steps/13-provisioned-tools-instruction-drift-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
STEP_FILE="$REPO_ROOT/src/scripts/checks/check-steps/13-repo-policy-data.sh"
readonly REPO_ROOT STEP_FILE

INSTR_REL="src/users/default/agents/instructions/nucleus-provisioned-tools.instructions.md"
CORE_REL="src/modules/core.nix"
DESIRED_REL="src/modules/packages/desired.json"
readonly INSTR_REL CORE_REL DESIRED_REL

run_subcheck() { # <fixture-repo> <out-file>
  local rc=0
  (
    bash -c '
      set -euo pipefail
      . "$1/src/scripts/checks/check-lib.sh"
      . "$1/src/scripts/checks/check-steps/13-repo-policy-data.sh"
      declare -A _ctx=([HAS_ARGS]=false [REPO_ROOT]="$2")
      run_provisioned_tools_instruction_drift _ctx
    ' _ "$REPO_ROOT" "$1"
  ) >"$2" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

make_fixture() {
  FIXTURE_REPO="$(mktemp -d)"
  mkdir -p "$FIXTURE_REPO/src/modules" "$FIXTURE_REPO/src/modules/packages" "$FIXTURE_REPO/src/users/default/agents/instructions"
}

write_core() {
  cat >"$FIXTURE_REPO/$CORE_REL" <<'NIX'
let
  managedPackages = {
    default = {
      category = "cli";
    };
    keep-cli = {
      category = "cli";
    };
    skip-gui = {
      category = "gui";
    };
    inter = {
      category = "cli";
    };
  };

  packageConfig = config.nucleus.packages.selection;
in
{}
NIX
}

write_desired() {
  cat >"$FIXTURE_REPO/$DESIRED_REL" <<'JSON'
{
  "$schema": "./desired.schema.json",
  "bun": {
    "MacBook": [
      { "name": "desired-tool" }
    ]
  }
}
JSON
}

write_instruction() {
  printf '%s\n' "$@" >"$FIXTURE_REPO/$INSTR_REL"
}

test_passes_when_required_names_present_and_exclusions_absent() {
  local out rc=0
  make_fixture
  write_core
  write_desired
  # shellcheck disable=SC2016 # reason: backticks are literal fixture content
  write_instruction 'Tools: `keep-cli` and `desired-tool` only.'
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 0 ] && [ "${out#*provisioned tools instruction drift policy passed}" != "$out" ]; then
    assert_pass "required managed CLI and desired names pass; gui, font, and default are excluded"
  else
    assert_fail "required managed CLI and desired names pass; gui, font, and default are excluded" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_missing_managed_cli_name_fails() {
  local out rc=0
  make_fixture
  write_core
  write_desired
  # shellcheck disable=SC2016 # reason: backticks are literal fixture content
  write_instruction 'Tools: `desired-tool` only.'
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && [ "${out#*missing required tool name}" != "$out" ] && [ "${out#*keep-cli}" != "$out" ]; then
    assert_pass "a missing managedPackages CLI name fails and names the tool"
  else
    assert_fail "a missing managedPackages CLI name fails and names the tool" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_missing_desired_name_fails() {
  local out rc=0
  make_fixture
  write_core
  write_desired
  # shellcheck disable=SC2016 # reason: backticks are literal fixture content
  write_instruction 'Tools: `keep-cli` only.'
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && [ "${out#*desired-tool}" != "$out" ]; then
    assert_pass "a missing desired.json name fails and names the tool"
  else
    assert_fail "a missing desired.json name fails and names the tool" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_missing_instruction_fails() {
  local out rc=0
  make_fixture
  write_core
  write_desired
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && [ "${out#*instruction not found}" != "$out" ]; then
    assert_pass "a missing instruction file fails"
  else
    assert_fail "a missing instruction file fails" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_registered_as_ctx() {
  if grep -qF '"provisioned tools instruction drift|run_provisioned_tools_instruction_drift|ctx"' "$STEP_FILE"; then
    assert_pass "the sub-check is registered with the ctx style"
  else
    assert_fail "the sub-check is registered with the ctx style" "no ctx registration in $STEP_FILE"
  fi
}

test_live_repo_passes() {
  local live_out out rc=0
  live_out="$(mktemp)"
  rc="$(run_subcheck "$REPO_ROOT" "$live_out")"
  out="$(cat "$live_out")"
  rm -f "$live_out"
  if [ "$rc" -eq 0 ]; then
    assert_pass "the live repo passes the provisioned tools instruction drift check"
  else
    assert_fail "the live repo passes the provisioned tools instruction drift check" "rc=$rc output=[$out]"
  fi
}

section 1 "fixture behaviour"
test_passes_when_required_names_present_and_exclusions_absent
test_missing_managed_cli_name_fails
test_missing_desired_name_fails
test_missing_instruction_fails

section 2 "registration and live repo"
test_registered_as_ctx
test_live_repo_passes

finish_tests
