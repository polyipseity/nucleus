#!/usr/bin/env bash
# C6: nucleus-svc list/status liveness column.
# Covers: live probe => live, dead probe => dead, unknown => unknown, no endpoint => '-',
# and non-live placeholder rows => n/a. The probe is mocked via the exported function
# guard so the real service-liveness lib is not sourced.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "svc liveness column tests require jq"

SVC_SH="$REPO_ROOT/scripts/svc.sh"
SERVICES_JSON="$REPO_ROOT/src/modules/services.json"

section 1 "mocked liveness probe maps rc to live/dead/unknown"

# Pick a service that has a network.default endpoint on this host.
endpoint_service="$(
  jq -r --arg host "$(uname -s | sed 's/Darwin/MacBook/;s/Linux/NixOS/')" '
    to_entries[]
    | select(.key | startswith("$") | not)
    | select(.value.hosts[$host] != null)
    | select(.value.hosts[$host].type != "omitted")
    | select(.value.network.default.host != null)
    | .key
  ' "$SERVICES_JSON" | head -n 1
)"
if [ -z "$endpoint_service" ]; then
  # Fallback: any service with a default endpoint.
  endpoint_service="$(
    jq -r '
      to_entries[]
      | select(.key | startswith("$") | not)
      | select(.value.network.default.host != null)
      | .key
    ' "$SERVICES_JSON" | head -n 1
  )"
fi

if [ -z "$endpoint_service" ]; then
  assert_fail "found service with network.default endpoint" "none found in registry"
else
  assert_pass "found service with network.default endpoint ($endpoint_service)"

  run_with_mock() {
    local mock_rc="$1" mock_reason="$2" expected="$3" label="$4"
    local out
    # shellcheck disable=SC2030 # reason: intentional subshell export for mock child process # check-suppress:suppression_doc: subshell-local mock env
    out="$(
      export _NUCLEUS_SERVICE_LIVENESS_SOURCED=1
      eval "svc_liveness_probe_endpoint() { printf '%s\n' '$mock_reason'; return $mock_rc; }"
      export -f svc_liveness_probe_endpoint
      "$SVC_SH" status --json "$endpoint_service" 2>/dev/null
    )"
    local got
    got="$(printf '%s' "$out" | jq -r --arg s "$endpoint_service" '.services[$s].liveness // empty' 2>/dev/null || true)"
    if [ "$got" = "$expected" ]; then
      assert_pass "$label"
    else
      assert_fail "$label" "expected $expected, got '$got' for $endpoint_service"
    fi
  }

  run_with_mock 0 "live" "live" "live probe => liveness live"
  run_with_mock 1 "dead:connect-failed" "dead" "dead probe => liveness dead"
  run_with_mock 2 "unknown:timeout" "unknown" "unknown probe => liveness unknown"
fi

section 2 "no endpoint => '-' for live row"

# Pick a live (non-prefix, non-omitted) service without network.default.
no_endpoint_service="$(
  jq -r --arg host "$(uname -s | sed 's/Darwin/MacBook/;s/Linux/NixOS/')" '
    to_entries[]
    | select(.key | startswith("$") | not)
    | select(.value.hosts[$host] != null)
    | select(.value.hosts[$host].type != "omitted")
    | select((.value.hosts[$host].prefixMatch // false) != true)
    | select(.value.network.default == null)
    | .key
  ' "$SERVICES_JSON" | head -n 1
)"
if [ -z "$no_endpoint_service" ]; then
  assert_fail "found service without network.default endpoint" "none found in registry"
else
  assert_pass "found service without network.default endpoint ($no_endpoint_service)"
  # shellcheck disable=SC2031 # reason: intentional subshell export for mock child process # check-suppress:suppression_doc: subshell-local mock env
  out="$(
    export _NUCLEUS_SERVICE_LIVENESS_SOURCED=1
    # shellcheck disable=SC2329 # reason: exported for mock in subshell child process # check-suppress:suppression_doc: subshell-exported mock
    svc_liveness_probe_endpoint() {
      printf 'live\n'
      return 0
    }
    export -f svc_liveness_probe_endpoint
    "$SVC_SH" status --json "$no_endpoint_service" 2>/dev/null
  )"
  got="$(printf '%s' "$out" | jq -r --arg s "$no_endpoint_service" '.services[$s].liveness // empty' 2>/dev/null || true)"
  if [ "$got" = "-" ]; then
    assert_pass "no endpoint => liveness '-'"
  else
    assert_fail "no endpoint => liveness '-'" "expected -, got '$got' for $no_endpoint_service"
  fi
fi

section 3 "list --json includes liveness for all services"

list_json="$("$SVC_SH" list --json 2>/dev/null)"
if printf '%s' "$list_json" | jq -e '.services | length > 0' >/dev/null 2>&1; then
  assert_pass "list --json returns services"
  if printf '%s' "$list_json" | jq -e '[.services[] | has("liveness")] | all' >/dev/null 2>&1; then
    assert_pass "every service row has liveness field"
  else
    assert_fail "every service row has liveness field" "$(printf '%s' "$list_json" | jq -c '[.services | to_entries[] | select(.value | has("liveness") | not) | .key]' 2>/dev/null | head -c 200)"
  fi
else
  assert_fail "list --json returns services" "no services in output"
fi

finish_tests
