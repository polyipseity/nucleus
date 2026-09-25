#!/usr/bin/env bash
# Guard tests for the lockfile `psgallery` section (PSGallery module pins).
#
# The section is named for its source, PSGallery, not for the `pwsh` tool: the
# entries are PowerShell modules, and `pwsh` is also a tool name and a check-step
# id that keeps that spelling. Entries are `string | {version, hash}` so a nupkg
# can be pinned by SHA256, because PSGallery has no release-age delay.
#
# Asserted here:
#   * the section is named `psgallery`, and no `pwsh` section exists
#   * both entry forms validate against lockfile.schema.json
#   * an object-form entry fails validation when `hash` or `version` is missing,
#     and when the hash is not SRI
#   * every pinned entry in the real lockfile is one of the two forms
#   * the enforcement probe reads the version from either form
#
# Run with: bash tests/scripts/psgallery-lockfile-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "psgallery lockfile tests"
require_command check-jsonschema "psgallery lockfile schema tests"
require_command pwsh "psgallery enforcement probe"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
LOCKFILE="$REPO_ROOT/src/lockfiles/lockfile.json"
SCHEMA="$REPO_ROOT/src/lockfiles/lockfile.schema.json"
ENFORCEMENT_LIB="$REPO_ROOT/src/scripts/checks/lockfile-enforcement-lib.sh"

# A real SRI SHA256 (of the three bytes 'abc'), in the exact form
# `nix store prefetch-file --json --hash-type sha256` emits.
SRI_ABC='sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0='

section "psgallery-lockfile" "PSGallery lockfile section"

_tmpdir="$(mktemp -d)"
trap 'rm -rf -- "$_tmpdir"' EXIT

# Write a copy of the real lockfile with its psgallery section replaced.
write_lockfile() {
  jq --argjson psgallery "$1" '.psgallery = $psgallery' "$LOCKFILE" >"$_tmpdir/lockfile.json"
}

# Validate a candidate psgallery section against the real schema. Prints the
# validator output; exits 0 when the lockfile is schema-valid.
validate_psgallery() {
  write_lockfile "$1"
  check-jsonschema --schemafile "$SCHEMA" "$_tmpdir/lockfile.json" 2>&1
}

# --- section name ------------------------------------------------------------

if jq -e 'has("psgallery")' "$LOCKFILE" >/dev/null 2>&1; then
  assert_pass "lockfile.json declares the psgallery section"
else
  assert_fail "lockfile.json declares the psgallery section" "keys: $(jq -r 'keys | join(",")' "$LOCKFILE")"
fi

if jq -e 'has("pwsh")' "$LOCKFILE" >/dev/null 2>&1; then
  assert_fail "lockfile.json has no pwsh section" "the tool name must not be a section name"
else
  assert_pass "lockfile.json has no pwsh section"
fi

# --- schema: both entry forms ------------------------------------------------

if validate_psgallery '{"Pester":"6.2.0"}' >/dev/null 2>&1; then
  assert_pass "a plain version string validates"
else
  assert_fail "a plain version string validates" "$(validate_psgallery '{"Pester":"6.2.0"}')"
fi

if validate_psgallery "{\"Pester\":{\"hash\":\"$SRI_ABC\",\"version\":\"6.2.0\"}}" >/dev/null 2>&1; then
  assert_pass "a {version, hash} object validates"
else
  assert_fail "a {version, hash} object validates" "$(validate_psgallery "{\"Pester\":{\"hash\":\"$SRI_ABC\",\"version\":\"6.2.0\"}}")"
fi

# --- schema: bad object forms fail ------------------------------------------

if validate_psgallery '{"Pester":{"version":"6.2.0"}}' >/dev/null 2>&1; then
  assert_fail "an object without a hash fails validation" "accepted {\"version\"} alone"
else
  assert_pass "an object without a hash fails validation"
fi

if validate_psgallery '{"Pester":{"hash":"deadbeef","version":"6.2.0"}}' >/dev/null 2>&1; then
  assert_fail "an object with a non-SRI hash fails validation" "accepted \"deadbeef\""
else
  assert_pass "an object with a non-SRI hash fails validation"
fi

if validate_psgallery "{\"Pester\":{\"hash\":\"$SRI_ABC\"}}" >/dev/null 2>&1; then
  assert_fail "an object without a version fails validation" "accepted {\"hash\"} alone"
else
  assert_pass "an object without a version fails validation"
fi

# --- real lockfile entries ---------------------------------------------------

_bad_entries="$(jq -r '
  .psgallery | to_entries[]
  | select((.value | type) != "string")
  | select(
      (.value | type) != "object"
      or (.value | has("version") | not)
      or (.value | has("hash") | not)
      or (.value.hash | test("^sha256-[A-Za-z0-9+/]{43}=$") | not)
    )
  | .key' "$LOCKFILE")"
if [ -z "$_bad_entries" ]; then
  assert_pass "every pinned psgallery entry is a version string or an SRI-hashed object"
else
  assert_fail "every pinned psgallery entry is a version string or an SRI-hashed object" "$(printf '%s' "$_bad_entries" | tr '\n' ' ')"
fi

# --- enforcement probe -------------------------------------------------------

# shellcheck disable=SC2016 # reason: literal source-text match, not shell expansion
if grep -qF '_lfe_check_psgallery "$_lf_data"' "$ENFORCEMENT_LIB"; then
  assert_pass "the enforcement entry point calls _lfe_check_psgallery"
else
  assert_fail "the enforcement entry point calls _lfe_check_psgallery" "call site not found in $(basename "$ENFORCEMENT_LIB")"
fi

if grep -qE '^_lfe_check_pwsh\(\)' "$ENFORCEMENT_LIB"; then
  assert_fail "the pwsh-named probe is gone" "_lfe_check_pwsh still defined"
else
  assert_pass "the pwsh-named probe is gone"
fi

# Run the probe against a fixture whose module names are not installed, so the
# drift messages name the version the probe read from each entry form.
_probe_fixture="{\"psgallery\":{\"NucleusProbeFixtureObj\":{\"hash\":\"$SRI_ABC\",\"version\":\"9.9.9\"},\"NucleusProbeFixturePlain\":\"8.8.8\"}}"
_probe_out="$(
  set +e
  # The probe library expects say/warn/error and jq; it does not source lib.sh.
  # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
  . "$REPO_ROOT/src/scripts/lib/lib.sh"
  # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
  . "$ENFORCEMENT_LIB"
  _lfe_check_psgallery "$_probe_fixture" jq 2>&1
  echo "probe-run-complete"
)"
for _fixture in "NucleusProbeFixtureObj:9.9.9" "NucleusProbeFixturePlain:8.8.8"; do
  _mod="${_fixture%%:*}"
  _version="${_fixture##*:}"
  if printf '%s\n' "$_probe_out" | grep -qF "psgallery.$_mod: expected $_version, not installed"; then
    assert_pass "the probe reads version $_version from the $_mod entry form"
  else
    assert_fail "the probe reads version $_version from the $_mod entry form" "$(printf '%s' "$_probe_out" | tr '\n' '|')"
  fi
done

# A pinned version that cannot match the installed one proves the probe really
# queries the installed module rather than only echoing the pin.
_drift_out="$(
  set +e
  # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
  . "$REPO_ROOT/src/scripts/lib/lib.sh"
  # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
  . "$ENFORCEMENT_LIB"
  _lfe_check_psgallery '{"psgallery":{"Pester":"0.0.1","PSScriptAnalyzer":{"hash":"'"$SRI_ABC"'","version":"0.0.1"}}}' jq 2>&1
  echo "probe-run-complete"
)"
for _mod in Pester PSScriptAnalyzer; do
  if printf '%s\n' "$_drift_out" | grep -qE "psgallery.$_mod: expected 0\.0\.1, installed [0-9]"; then
    assert_pass "the probe compares the $_mod pin against the installed version"
  else
    assert_fail "the probe compares the $_mod pin against the installed version" "$(printf '%s' "$_drift_out" | tr '\n' '|')"
  fi
done

finish_tests
