#!/usr/bin/env bash
# Focused contract for both service-registry check-step twins and services.schema.json:
# windows-user-autostart is a real type with a required carrier name, while an
# unknown type must still fail every gate.
#
# Run with: bash tests/scripts/check-steps/service-registry-type-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

CHECKOUT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
init_test_state
require_command jq "the registry gate reads services.json through jq"
require_command check-jsonschema "the schema gate validates services.json"
require_command pwsh "the Windows twin is exercised through pwsh"

# check-lib.sh resolves the repo root from NUCLEUS_REPO_ROOT, set to the isolated
# test home above, so sourcing it performs no repository lookup.
# shellcheck source=../../../src/scripts/checks/check-lib.sh
. "$CHECKOUT_ROOT/src/scripts/checks/check-lib.sh"
# shellcheck source=../../../src/scripts/checks/check-steps/08-service-registry.sh
. "$CHECKOUT_ROOT/src/scripts/checks/check-steps/08-service-registry.sh"

FIXTURE_ROOT="$(mktemp -d)"
mkdir -p "$FIXTURE_ROOT/src/modules" "$FIXTURE_ROOT/src/users"
cp "$CHECKOUT_ROOT/src/modules/host-platform-registry.json" "$FIXTURE_ROOT/src/modules/host-platform-registry.json"
readonly FIXTURE_ROOT

prepare_registry() {
  local filter="$1"
  cp "$CHECKOUT_ROOT/src/modules/services.json" "$FIXTURE_ROOT/src/modules/services.json"
  if [ -n "$filter" ]; then
    jq "$filter" "$CHECKOUT_ROOT/src/modules/services.json" >"$FIXTURE_ROOT/src/modules/services-mutated.json"
    cp "$FIXTURE_ROOT/src/modules/services-mutated.json" "$FIXTURE_ROOT/src/modules/services.json"
  fi
}

check_step_status() {
  local filter="$1" output="$2"
  prepare_registry "$filter"
  # shellcheck disable=SC2034 # reason: run_service_registry reads this context by nameref
  local -A step_ctx=([HAS_ARGS]=false [REPO_ROOT]="$FIXTURE_ROOT")
  run_service_registry step_ctx >"$output" 2>&1
}

schema_status() {
  local filter="$1" output="$2"
  prepare_registry "$filter"
  check-jsonschema --schemafile "$CHECKOUT_ROOT/src/modules/services.schema.json" \
    "$FIXTURE_ROOT/src/modules/services.json" >"$output" 2>&1
}

# Invoke the registered Windows step action against the same fixture root the
# POSIX twin uses. The step is declared windows-only, so check.ps1 skips it on
# macOS; calling the action directly still tests the real gate.
powershell_step_status() {
  local filter="$1" output="$2"
  prepare_registry "$filter"
  # shellcheck disable=SC2016 # reason: PowerShell variables must reach pwsh unexpanded by bash
  NUCLEUS_TEST_CHECKOUT_ROOT="$CHECKOUT_ROOT" NUCLEUS_TEST_FIXTURE_ROOT="$FIXTURE_ROOT" \
    pwsh -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  $checkout = $env:NUCLEUS_TEST_CHECKOUT_ROOT
  $fixture = $env:NUCLEUS_TEST_FIXTURE_ROOT
  $FrameworkDir = Join-Path $checkout "src/scripts/lib"
  $RepoRoot = $checkout
  $CheckDir = Join-Path $checkout "src/scripts/checks"
  . (Join-Path $CheckDir "check-lib.ps1")
  . (Join-Path $CheckDir "check-steps/08-service-registry.ps1")
  $index = $script:StepIds.IndexOf("service-registry")
  if ($index -lt 0) { throw "service-registry step was not registered" }
  $ctx = [pscustomobject]@{ RepoRoot = $fixture }
  $lines = @(& $script:StepActions[$index] -Context $ctx)
  $lines | ForEach-Object { if ($_ -isnot [bool]) { [Console]::Out.WriteLine([string]$_) } }
  if ($lines[-1] -ne $true) { exit 1 }
' >"$output" 2>&1
}

section 1 "service registry type contract"

if check_step_status "" "$FIXTURE_ROOT/accepted-step.out"; then
  assert_pass "check step accepts windows-user-autostart with a carrier name"
else
  assert_fail "check step accepts windows-user-autostart with a carrier name" \
    "$(tr '\n' ' ' <"$FIXTURE_ROOT/accepted-step.out")"
fi

if check_step_status '.["hermes-agent"].hosts.Windows.type = "not-a-service-type"' \
  "$FIXTURE_ROOT/unknown-step.out"; then
  assert_fail "check step rejects an unknown service type" "the gate returned success"
elif grep -q "invalid type 'not-a-service-type'" "$FIXTURE_ROOT/unknown-step.out"; then
  assert_pass "check step rejects an unknown service type"
else
  assert_fail "check step rejects an unknown service type" \
    "$(tr '\n' ' ' <"$FIXTURE_ROOT/unknown-step.out")"
fi

if check_step_status 'del(.["hermes-agent"].hosts.Windows.service)' \
  "$FIXTURE_ROOT/no-carrier-step.out"; then
  assert_fail "check step requires the autostart carrier name" "the gate returned success"
elif grep -q "missing required fields for type 'windows-user-autostart'" "$FIXTURE_ROOT/no-carrier-step.out"; then
  assert_pass "check step requires the autostart carrier name"
else
  assert_fail "check step requires the autostart carrier name" \
    "$(tr '\n' ' ' <"$FIXTURE_ROOT/no-carrier-step.out")"
fi

section 2 "Windows twin service registry type contract"

if powershell_step_status "" "$FIXTURE_ROOT/accepted-ps-step.out"; then
  assert_pass "Windows twin accepts windows-user-autostart with a carrier name"
else
  assert_fail "Windows twin accepts windows-user-autostart with a carrier name" \
    "$(tr '\n' ' ' <"$FIXTURE_ROOT/accepted-ps-step.out")"
fi

if powershell_step_status '.["hermes-agent"].hosts.Windows.type = "not-a-service-type"' \
  "$FIXTURE_ROOT/unknown-ps-step.out"; then
  assert_fail "Windows twin rejects an unknown service type" "the gate returned success"
elif grep -q "invalid type 'not-a-service-type'" "$FIXTURE_ROOT/unknown-ps-step.out"; then
  assert_pass "Windows twin rejects an unknown service type"
else
  assert_fail "Windows twin rejects an unknown service type" \
    "$(tr '\n' ' ' <"$FIXTURE_ROOT/unknown-ps-step.out")"
fi

if powershell_step_status 'del(.["hermes-agent"].hosts.Windows.service)' \
  "$FIXTURE_ROOT/no-carrier-ps-step.out"; then
  assert_fail "Windows twin requires the autostart carrier name" "the gate returned success"
elif grep -q "missing required fields for type 'windows-user-autostart'" \
  "$FIXTURE_ROOT/no-carrier-ps-step.out"; then
  assert_pass "Windows twin requires the autostart carrier name"
else
  assert_fail "Windows twin requires the autostart carrier name" \
    "$(tr '\n' ' ' <"$FIXTURE_ROOT/no-carrier-ps-step.out")"
fi

section 3 "services schema type contract"

if schema_status "" "$FIXTURE_ROOT/accepted-schema.out"; then
  assert_pass "schema accepts windows-user-autostart with a carrier name"
else
  assert_fail "schema accepts windows-user-autostart with a carrier name" \
    "$(tr '\n' ' ' <"$FIXTURE_ROOT/accepted-schema.out")"
fi

if schema_status '.["hermes-agent"].hosts.Windows.type = "not-a-service-type"' \
  "$FIXTURE_ROOT/unknown-schema.out"; then
  assert_fail "schema rejects an unknown service type" "validation returned success"
else
  assert_pass "schema rejects an unknown service type"
fi

finish_tests
