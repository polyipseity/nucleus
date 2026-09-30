#!/usr/bin/env bash
# Guard tests for the lockfile `whisper` section (whisper.cpp ggml model pins).
#
# The section pins a data file, not a program: no package manager ships the
# ggml weights, so this lockfile entry is the only version pin the model has on
# any host. Entries are always the object form {url, revision, hash}, because a
# bare version string cannot express a content hash.
#
# Asserted here:
#   * the section exists and every entry is a {url, revision, hash} object
#   * the schema rejects an object missing url, revision or hash, and a hash
#     that is not SRI
#   * every url embeds its own 40-character revision, so a mutable `main` ref
#     cannot masquerade as a pinned one
#   * _lfe_check_whisper is wired into the enforcement entry point
#   * the probe hashes the deployed copy: it reports a missing model, a
#     tampered model, and a matching model, and exits non-zero on the first two
#
# Run with: bash tests/scripts/whisper-lockfile-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "whisper lockfile tests"
require_command check-jsonschema "whisper lockfile schema tests"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
LOCKFILE="$REPO_ROOT/src/lockfiles/lockfile.json"
SCHEMA="$REPO_ROOT/src/lockfiles/lockfile.schema.json"
ENFORCEMENT_LIB="$REPO_ROOT/src/scripts/checks/lockfile-enforcement-lib.sh"

# A real SRI SHA256 (of the three bytes 'abc'), in the exact form
# `nix store prefetch-file --json --hash-type sha256` emits.
SRI_ABC='sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0='
# The same value in hex, the form the POSIX probe compares against.
HEX_ABC='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
REV='5359861c739e955e79d9a303bcbc70fb988958b1'

section "whisper-lockfile" "whisper model lockfile section"

_tmpdir="$(mktemp -d)"
trap 'rm -rf -- "$_tmpdir"' EXIT

# Write a copy of the real lockfile with its whisper section replaced.
write_lockfile() {
  jq --argjson whisper "$1" '.whisper = $whisper' "$LOCKFILE" >"$_tmpdir/lockfile.json"
}

# Validate a candidate whisper section against the real schema.
validate_whisper() {
  write_lockfile "$1"
  check-jsonschema --schemafile "$SCHEMA" "$_tmpdir/lockfile.json" 2>&1
}

_good_pin="{\"url\":\"https://example.invalid/resolve/$REV/ggml-base.en.bin\",\"revision\":\"$REV\",\"hash\":\"$SRI_ABC\"}"

# --- section presence --------------------------------------------------------

if jq -e 'has("whisper")' "$LOCKFILE" >/dev/null 2>&1; then
  assert_pass "lockfile.json declares the whisper section"
else
  assert_fail "lockfile.json declares the whisper section" "keys: $(jq -r 'keys | join(",")' "$LOCKFILE")"
fi

# --- schema: the object form, and each missing field -------------------------

if validate_whisper "{\"ggml-base.en.bin\":$_good_pin}" >/dev/null 2>&1; then
  assert_pass "a {url, revision, hash} object validates"
else
  assert_fail "a {url, revision, hash} object validates" "$(validate_whisper "{\"ggml-base.en.bin\":$_good_pin}")"
fi

for _missing in url revision hash; do
  _partial="$(jq -c --arg f "$_missing" 'del(.[$f])' <<<"$_good_pin")"
  if validate_whisper "{\"ggml-base.en.bin\":$_partial}" >/dev/null 2>&1; then
    assert_fail "an object without $_missing fails validation" "accepted the two-field object"
  else
    assert_pass "an object without $_missing fails validation"
  fi
done

if validate_whisper '{"ggml-base.en.bin":{"url":"https://example.invalid/x.bin","revision":"abc","hash":"deadbeef"}}' >/dev/null 2>&1; then
  assert_fail "an object with a non-SRI hash fails validation" 'accepted "deadbeef"'
else
  assert_pass "an object with a non-SRI hash fails validation"
fi

# A bare version string cannot carry a content hash, so the section must reject
# it outright rather than accept a pin nothing can verify.
if validate_whisper '{"ggml-base.en.bin":"1.5.0"}' >/dev/null 2>&1; then
  assert_fail "a bare version string fails validation" "accepted a hashless pin"
else
  assert_pass "a bare version string fails validation"
fi

# --- real lockfile entries ---------------------------------------------------

# Every conjunct is total for any JSON value. jq's `or` does not short-circuit,
# so a plain `has("url")` on a string entry raises instead of returning false,
# and the whole query dies on the first malformed entry rather than reporting
# it. `type` and `tostring` are the total forms.
_bad_entries="$(jq -r '
  .whisper | to_entries[]
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
  assert_pass "every whisper entry is a {url, revision, hash} object whose url embeds its revision"
else
  assert_fail "every whisper entry is a {url, revision, hash} object whose url embeds its revision" "$(printf '%s' "$_bad_entries" | tr '\n' ' ')"
fi

# The mutable-ref case is the one that would break reproducibility, so assert it
# against the real file shape rather than only through the schema.
if jq -e --arg rev "$REV" '
    .whisper | to_entries[]
    | select((.value.url // "" | tostring | contains($rev)) | not)
    | .key' "$LOCKFILE" | grep -q .; then
  assert_fail "no whisper url resolves through a mutable ref" "$(jq -r '.whisper | keys | join(",")' "$LOCKFILE")"
else
  assert_pass "no whisper url resolves through a mutable ref"
fi

# --- enforcement wiring ------------------------------------------------------

# shellcheck disable=SC2016 # reason: literal source-text match for the call site, not shell expansion
if grep -qF '_lfe_check_whisper "$_lf_data"' "$ENFORCEMENT_LIB"; then
  assert_pass "the enforcement entry point calls _lfe_check_whisper"
else
  assert_fail "the enforcement entry point calls _lfe_check_whisper" "call site not found in $(basename "$ENFORCEMENT_LIB")"
fi

if grep -qE '^_lfe_check_whisper\(\)' "$ENFORCEMENT_LIB"; then
  assert_pass "_lfe_check_whisper is defined"
else
  assert_fail "_lfe_check_whisper is defined" "definition not found in $(basename "$ENFORCEMENT_LIB")"
fi

# --- enforcement probe behaviour --------------------------------------------

# Run the probe against a fixture user root holding a model whose content is the
# three bytes 'abc', so the pinned SRI and the hex the probe reports are both
# known values. The probe library expects say/error and jq; it does not source
# lib.sh, so the caller provides both plus the user root the probe reads.
run_probe() {
  # $1: lockfile JSON, $2: user root
  (
    set +e
    export NUCLEUS_USER_ROOT="$2"
    # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
    . "$REPO_ROOT/src/scripts/lib/lib.sh"
    # shellcheck disable=SC1090 # reason: repo-root-relative path, resolved at runtime
    . "$ENFORCEMENT_LIB"
    _lfe_check_whisper "$1" jq 2>&1
    echo "probe-exit=$?"
  )
}

_fixture_root="$_tmpdir/userroot"
mkdir -p "$_fixture_root/models"
printf 'abc' >"$_fixture_root/models/ggml-base.en.bin"
printf 'tampered' >"$_fixture_root/models/ggml-tampered.bin"
_matching="{\"whisper\":{\"ggml-base.en.bin\":{\"hash\":\"$SRI_ABC\",\"revision\":\"$REV\",\"url\":\"https://example.invalid/$REV/x\"}}}"

# A matching deployment must pass and name the hash it verified.
_out="$(run_probe "$_matching" "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=0" &&
  printf '%s\n' "$_out" | grep -qF "$HEX_ABC"; then
  assert_pass "a matching model passes the probe and reports the verified digest"
else
  assert_fail "a matching model passes the probe and reports the verified digest" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

# The same pin against tampered content must fail, and the message must carry
# both digests so the drift is diagnosable without re-hashing by hand.
_tampered="{\"whisper\":{\"ggml-tampered.bin\":{\"hash\":\"$SRI_ABC\",\"revision\":\"$REV\",\"url\":\"https://example.invalid/$REV/x\"}}}"
_out="$(run_probe "$_tampered" "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=1" &&
  printf '%s\n' "$_out" | grep -qF "expected sha256:$HEX_ABC"; then
  assert_pass "a tampered model fails the probe and names the expected digest"
else
  assert_fail "a tampered model fails the probe and names the expected digest" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

# A pin with nothing deployed must fail as a missing file, not pass quietly.
_missing="{\"whisper\":{\"ggml-absent.bin\":{\"hash\":\"$SRI_ABC\",\"revision\":\"$REV\",\"url\":\"https://example.invalid/$REV/x\"}}}"
_out="$(run_probe "$_missing" "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=1" &&
  printf '%s\n' "$_out" | grep -qF "not deployed at"; then
  assert_pass "a model that was never deployed fails the probe"
else
  assert_fail "a model that was never deployed fails the probe" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

# An empty section is a no-op pass: a host that pins no model must not report
# drift it cannot have.
_out="$(run_probe '{"whisper":{}}' "$_fixture_root")"
if printf '%s\n' "$_out" | grep -qF "probe-exit=0"; then
  assert_pass "an empty whisper section is a no-op pass"
else
  assert_fail "an empty whisper section is a no-op pass" "$(printf '%s\n' "$_out" | tr '\n' '|')"
fi

finish_tests
