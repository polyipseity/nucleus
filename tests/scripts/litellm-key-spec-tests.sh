#!/usr/bin/env bash
# Test: the Windows LiteLLM key filter matches the POSIX one.
#
# The gateway needs one environment variable per AI provider key. POSIX picks
# them with envLib.mkSecretArgsForConsumer, which filters the env-secrets
# catalog on the consumer "litellm"; Get-LiteLLMKeySpec.ps1 is the Windows half
# of that same filter. Every entry in the shipped catalog is a litellm
# consumer, so a test that only reads the real catalog cannot tell a working
# filter from a missing one -- both return all 9. The mixed-consumer fixture
# below is what makes the predicate observable.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command pwsh "pwsh is required to exercise the Windows key filter"
require_command python3 "python3 independently derives the expected key set from the catalog"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
MODULE="$REPO_ROOT/src/platforms/Windows/modules/Get-LiteLLMKeySpec.ps1"
CATALOG="$REPO_ROOT/src/modules/env/env-secrets.json"

# call_ps <expression> -- dot-sources the module and evaluates, echoing output
# and propagating a non-zero exit so a terminating throw is observable.
call_ps() {
  local _expr="$1" _status=0
  # shellcheck disable=SC2016 # reason: PowerShell variable references, not shell expansion
  pwsh -NoLogo -NoProfile -NonInteractive -Command "
    . '$MODULE'
    \$ErrorActionPreference = 'Stop'
    $_expr
  " || _status=$?
  return "$_status"
}

# names_ps <catalog-path> -- the names the filter selects, one per line.
names_ps() {
  local _path
  _path="'$(printf '%s' "$1" | sed "s/'/''/g")'"
  # shellcheck disable=SC2016 # reason: PowerShell variable references, not shell expansion
  pwsh -NoLogo -NoProfile -NonInteractive -Command "
    . '$MODULE'
    \$ErrorActionPreference = 'Stop'
    Get-LiteLLMKeySpec -CatalogPath $_path | ForEach-Object { \$_.name }
  "
}

# The expected set, derived from the catalog by something other than the code
# under test, so agreement is evidence rather than tautology.
expected_names() {
  python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    catalog = json.load(fh)
for entry in catalog["secrets"]:
    if "litellm" in entry.get("consumers", []):
        print(entry["name"])
' "$1"
}

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
MIXED_CATALOG="$FIXTURE_DIR/mixed.json"
cat >"$MIXED_CATALOG" <<'JSON'
{
  "secrets": [
    { "name": "key_for_litellm", "envVar": "KEY_LITELLM", "consumers": ["litellm"] },
    { "name": "key_for_something_else", "envVar": "KEY_ELSE", "consumers": ["other-consumer"] },
    { "name": "key_for_both", "envVar": "KEY_BOTH", "consumers": ["other-consumer", "litellm"] }
  ]
}
JSON
MISSING_CATALOG="$FIXTURE_DIR/absent.json"
NO_SECRETS_CATALOG="$FIXTURE_DIR/no-secrets.json"
printf '{ "notSecrets": [] }\n' >"$NO_SECRETS_CATALOG"

# The real catalog plus one entry that is not a litellm consumer. A distinct
# consumer string, because the filter compares the value for equality with
# "litellm" and only an exact match is selected.
INJECTED_NAME="env_key_injected_other_service"
INJECTED_CONSUMER="other-service"
INJECTED_CATALOG="$FIXTURE_DIR/live-plus-injected.json"
python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    catalog = json.load(fh)
catalog["secrets"].append({
    "name": sys.argv[3],
    "envVar": "KEY_INJECTED_OTHER_SERVICE",
    "sopsSource": "system",
    "consumers": [sys.argv[2]],
})
with open(sys.argv[4], "w", encoding="utf-8") as fh:
    json.dump(catalog, fh, indent=2)
' "$CATALOG" "$INJECTED_CONSUMER" "$INJECTED_NAME" "$INJECTED_CATALOG"

# count_secrets <catalog> -- the entry count, so a failed injection cannot make
# the case below pass by comparing the catalog against itself.
count_secrets() {
  python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(len(json.load(fh)["secrets"]))
' "$1"
}

# Every shipped secret is currently a litellm consumer, so assert the shape the
# caller depends on: a bare secret name, never a path. LiteLLM-run.ps1 joins
# $spec.file onto its own secrets directory, and Join-Path does not treat an
# absolute child as absolute, so a path here silently matches nothing at runtime.
test_selected_names_are_bare_not_paths() {
  local _out
  if _out="$(names_ps "$CATALOG" | grep -E '[/\\]|^[A-Za-z]:' || true)" && [ -z "$_out" ]; then
    assert_pass "selected names are bare secret names, not paths"
  else
    assert_fail "selected names are bare secret names, not paths" "path-like: $(echo "$_out" | tr '\n' ' ')"
  fi
}

# The discriminating case. A catalog holding a non-litellm consumer is the only
# input on which a working filter and a broken one differ.
test_filter_excludes_other_consumers() {
  local _got _want
  _got="$(names_ps "$MIXED_CATALOG" | sort | tr '\n' ' ')"
  _want="key_for_both key_for_litellm "
  if [ "$_got" = "$_want" ]; then
    assert_pass "non-litellm consumers are excluded (selected: ${_got% })"
  else
    assert_fail "non-litellm consumers are excluded" "selected [${_got% }], expected [${_want% }]"
  fi
}

# The pure-live case above cannot discriminate. Every shipped secret is
# currently a litellm consumer, so a filter that selected everything would
# agree with it, and its passing would prove nothing about the predicate. This
# case runs the catalog that actually ships with one non-litellm entry added,
# so the real artifact is exercised on the only input where a working filter
# and a broken one differ.
test_live_catalog_excludes_an_injected_other_consumer() {
  local _got _want _live _perturbed
  _live="$(count_secrets "$CATALOG")"
  _perturbed="$(count_secrets "$INJECTED_CATALOG")"
  if [ "$_perturbed" -ne $((_live + 1)) ]; then
    assert_fail "the real catalog filters an added non-litellm consumer out" "perturbation did not land: $_perturbed entries against $_live"
    return
  fi
  _got="$(names_ps "$INJECTED_CATALOG" | sort)"
  _want="$(expected_names "$INJECTED_CATALOG" | sort)"
  if [ "$_got" = "$_want" ] && [ -n "$_got" ] && ! printf '%s\n' "$_got" | grep -qx "$INJECTED_NAME"; then
    assert_pass "the real catalog filters an added non-litellm consumer out ($(printf '%s\n' "$_got" | wc -l | tr -d ' ') selected, $INJECTED_NAME excluded)"
  else
    assert_fail "the real catalog filters an added non-litellm consumer out" "got [$(echo "$_got" | tr '\n' ' ')] want [$(echo "$_want" | tr '\n' ' ')]"
  fi
}

# A missing catalog is a hard error. A silently empty key set is the defect
# being fixed: litellm starts, reports healthy, and fails only at request time.
test_missing_catalog_is_a_hard_error() {
  local _out _status=0
  _out="$(call_ps "Get-LiteLLMKeySpec -CatalogPath '$MISSING_CATALOG'" 2>&1)" || _status=$?
  if [ "$_status" -ne 0 ] && printf '%s' "$_out" | grep -q 'catalog not found'; then
    assert_pass "a missing catalog terminates with a located error"
  else
    assert_fail "a missing catalog terminates with a located error" "status=$_status out=$(printf '%s' "$_out" | tr '\n' ' ' | cut -c1-160)"
  fi
}

# A catalog that parses but carries no secrets array is the same failure wearing
# a different mask, and must not be read as "no keys needed".
test_catalog_without_secrets_array_is_a_hard_error() {
  local _out _status=0
  _out="$(call_ps "Get-LiteLLMKeySpec -CatalogPath '$NO_SECRETS_CATALOG'" 2>&1)" || _status=$?
  if [ "$_status" -ne 0 ] && printf '%s' "$_out" | grep -q "no 'secrets' array"; then
    assert_pass "a catalog with no secrets array terminates with a located error"
  else
    assert_fail "a catalog with no secrets array terminates with a located error" "status=$_status out=$(printf '%s' "$_out" | tr '\n' ' ' | cut -c1-160)"
  fi
}

test_selected_names_are_bare_not_paths
test_filter_excludes_other_consumers
test_live_catalog_excludes_an_injected_other_consumer
test_missing_catalog_is_a_hard_error
test_catalog_without_secrets_array_is_a_hard_error
finish_tests
