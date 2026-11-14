#!/usr/bin/env bash
# Guard tests for the lockfile `deepfilternet` section (DeepFilterNet3 ONNX model pins).
#
# Mirrors the whisper lockfile tests for the DeepFilterNet3_onnx.tar.gz pin.
#
# Asserted here:
#   * the section exists and every entry is a {url, revision, hash} object
#   * the schema rejects an object missing url, revision or hash, and a hash
#     that is not SRI
#   * every url embeds its own 40-character revision
#   * _lfe_check_deepfilternet is wired into the enforcement entry point
#   * the probe hashes the deployed copy: it reports a missing model, a
#     tampered model, and a matching model, and exits non-zero on the first two
#
# Run with: bash tests/scripts/deepfilternet-lockfile-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "deepfilternet lockfile tests"
require_command check-jsonschema "deepfilternet lockfile schema tests"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
LOCKFILE="$REPO_ROOT/src/lockfiles/lockfile.json"
SCHEMA="$REPO_ROOT/src/lockfiles/lockfile.schema.json"
ENFORCEMENT_LIB="$REPO_ROOT/src/scripts/checks/lockfile-enforcement-lib.sh"

# A real SRI SHA256 (of the three bytes 'abc'), in the exact form
# `nix store prefetch-file --json --hash-type sha256` emits.
SRI_ABC='sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0='
# The same value in hex, the form the POSIX probe compares against.
HEX_ABC='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
REV='978576aa8400552a4ce9730838c635aa30db5e61'

section "deepfilternet-lockfile" "deepfilternet model lockfile section"

_tmpdir="$(mktemp -d)"
trap 'rm -rf -- "$_tmpdir"' EXIT

# Write a copy of the real lockfile with its deepfilternet section replaced.
write_lockfile() {
  jq --argjson deepfilternet "$1" '.deepfilternet = $deepfilternet' "$LOCKFILE" >"$_tmpdir/lockfile.json"
}

# Validate a candidate deepfilternet section against the real schema.
validate_deepfilternet() {
  write_lockfile "$1"
  check-jsonschema --schemafile "$SCHEMA" "$_tmpdir/lockfile.json" 2>&1
}

_good_pin="{\"url\":\"https://raw.githubusercontent.com/Rikorose/DeepFilterNet/$REV/models/DeepFilterNet3_onnx.tar.gz\",\"revision\":\"$REV\",\"hash\":\"$SRI_ABC\"}"

# --- section presence --------------------------------------------------------

_has_section=false
if jq -e 'has("deepfilternet")' "$LOCKFILE" >/dev/null 2>&1; then
  _has_section=true
  assert_pass "lockfile.json declares the deepfilternet section"
else
  assert_fail "lockfile.json declares the deepfilternet section" "keys: $(jq -r 'keys | join(",")' "$LOCKFILE")"
fi

# --- schema: the object form, and each missing field -------------------------

if validate_deepfilternet "{\"DeepFilterNet3_onnx.tar.gz\":$_good_pin}" >/dev/null 2>&1; then
  assert_pass "a {url, revision, hash} object validates"
else
  assert_fail "a {url, revision, hash} object validates" "$(validate_deepfilternet "{\"DeepFilterNet3_onnx.tar.gz\":$_good_pin}")"
fi

for _missing in url revision hash; do
  _partial="$(jq -c --arg f "$_missing" 'del(.[$f])' <<<"$_good_pin")"
  if validate_deepfilternet "{\"DeepFilterNet3_onnx.tar.gz\":$_partial}" >/dev/null 2>&1; then
    assert_fail "an object without $_missing fails validation" "accepted the two-field object"
  else
    assert_pass "an object without $_missing fails validation"
  fi
done

if validate_deepfilternet '{"DeepFilterNet3_onnx.tar.gz":{"url":"https://example.invalid/x.tar.gz","revision":"abc","hash":"deadbeef"}}' >/dev/null 2>&1; then
  assert_fail "an object with a non-SRI hash fails validation" 'accepted "deadbeef"'
else
  assert_pass "an object with a non-SRI hash fails validation"
fi

# A bare version string cannot carry a content hash.
if validate_deepfilternet '{"DeepFilterNet3_onnx.tar.gz":"0.5.6"}' >/dev/null 2>&1; then
  assert_fail "a bare version string fails validation" "accepted a hashless pin"
else
  assert_pass "a bare version string fails validation"
fi

# --- real lockfile entries ---------------------------------------------------

if [ "$_has_section" = true ]; then
  # Total checks (type/tostring) so malformed entries are reported, not fatal.
  _bad_entries="$(jq -r '
    .deepfilternet | to_entries[]
    | . as $e
    | select(
        ($e.value | type) != "object"
        or ($e.value.url | type) != "string"
        or ($e.value.revision | type) != "string"
        or ($e.value.hash | type) != "string"
        or ($e.value.hash | tostring | test("^sha256-[A-Za-z0-9+/]{43}=$") | not)
        or (($e.value.revision | length) != 40)
        or ($e.value.url | tostring | contains($e.value.revision | tostring) | not)
      )
    | .key' "$LOCKFILE")"
  if [ -z "$_bad_entries" ]; then
    assert_pass "every deepfilternet entry is a {url, revision, hash} object whose url embeds its revision"
  else
    assert_fail "every deepfilternet entry is a {url, revision, hash} object whose url embeds its revision" "$(printf '%s' "$_bad_entries" | tr '\n' ' ')"
  fi

  # The mutable-ref case must not occur in the real file.
  if jq -e '
      .deepfilternet | to_entries[]
      | select((.value.url // "" | tostring | contains(.value.revision // "" | tostring)) | not)
      | .key' "$LOCKFILE" 2>/dev/null | grep -q .; then
    assert_fail "no deepfilternet url resolves through a mutable ref" "$(jq -r '.deepfilternet | keys | join(",")' "$LOCKFILE")"
  else
    assert_pass "no deepfilternet url resolves through a mutable ref"
  fi
else
  assert_fail "every deepfilternet entry is a {url, revision, hash} object whose url embeds its revision" "deepfilternet section missing"
  assert_fail "no deepfilternet url resolves through a mutable ref" "deepfilternet section missing"
fi

# --- enforcement wiring ------------------------------------------------------

# shellcheck disable=SC2016 # reason: literal source-text match for the call site, not shell expansion
if grep -qF '_lfe_check_deepfilternet "$_lf_data"' "$ENFORCEMENT_LIB"; then
  assert_pass "the enforcement entry point calls _lfe_check_deepfilternet"
else
  assert_fail "the enforcement entry point calls _lfe_check_deepfilternet" "call site not found in $(basename "$ENFORCEMENT_LIB")"
fi

if grep -qE '^_lfe_check_deepfilternet\(\)' "$ENFORCEMENT_LIB"; then
  assert_pass "_lfe_check_deepfilternet is defined"
else
  assert_fail "_lfe_check_deepfilternet is defined" "definition not found in $(basename "$ENFORCEMENT_LIB")"
fi

# --- enforcement probe behaviour --------------------------------------------

run_probe() {
  # $1: lockfile JSON, $2: user root
  (
    set +e
    export NUCLEUS_USER_ROOT="$2"
    # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
    . "$REPO_ROOT/src/scripts/lib/lib.sh"
    # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
    . "$ENFORCEMENT_LIB"
    _lfe_check_deepfilternet "$1" jq 2>&1
    echo "probe-exit=$?"
  )
}

_fixture_root="$_tmpdir/userroot"
mkdir -p "$_fixture_root/models"
printf 'abc' >"$_fixture_root/models/DeepFilterNet3_onnx.tar.gz"
printf 'tampered' >"$_fixture_root/models/DeepFilterNet3-tampered.tar.gz"
_matching="{\"deepfilternet\":{\"DeepFilterNet3_onnx.tar.gz\":{\"hash\":\"$SRI_ABC\",\"revision\":\"$REV\",\"url\":\"https://example.invalid/$REV/x\"}}}"

_out="$(run_probe "$_matching" "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=0" &&
  printf '%s\n' "$_out" | grep -qF "$HEX_ABC"; then
  assert_pass "a matching model passes the probe and reports the verified digest"
else
  assert_fail "a matching model passes the probe and reports the verified digest" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

_tampered="{\"deepfilternet\":{\"DeepFilterNet3-tampered.tar.gz\":{\"hash\":\"$SRI_ABC\",\"revision\":\"$REV\",\"url\":\"https://example.invalid/$REV/x\"}}}"
_out="$(run_probe "$_tampered" "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=1" &&
  printf '%s\n' "$_out" | grep -qF "expected sha256:$HEX_ABC"; then
  assert_pass "a tampered model fails the probe and names the expected digest"
else
  assert_fail "a tampered model fails the probe and names the expected digest" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

_missing="{\"deepfilternet\":{\"DeepFilterNet3-absent.tar.gz\":{\"hash\":\"$SRI_ABC\",\"revision\":\"$REV\",\"url\":\"https://example.invalid/$REV/x\"}}}"
_out="$(run_probe "$_missing" "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=1" &&
  printf '%s\n' "$_out" | grep -qF "not deployed at"; then
  assert_pass "a model that was never deployed fails the probe"
else
  assert_fail "a model that was never deployed fails the probe" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

_out="$(run_probe '{"deepfilternet":{}}' "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=0"; then
  assert_pass "an empty deepfilternet section is a no-op pass"
else
  assert_fail "an empty deepfilternet section is a no-op pass" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

finish_tests
