#!/usr/bin/env bash
# Tests for the shared instruction byte-cap validator.
#
# Each fixture spells out its byte totals, so the 100000-byte boundary is set by
# the test rather than by the code under test. The one-byte and missing-file
# cases are separate fixtures, which keeps a failure in one rule from being
# mistaken for a failure in the other.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

init_test_state
require_command python3 "the byte-cap validator is a Python script"

VALIDATOR="$REPO_ROOT/src/scripts/lib/instruction-byte-cap.py"
readonly VALIDATOR

WORK="$(mktemp -d)"
readonly WORK
# shellcheck disable=SC2064 # reason: WORK is readonly and resolved at trap-install time
trap "python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' '$WORK'" EXIT

make_fixture() { # <name> -> fixture root
  local root="$WORK/$1"
  python3 - "$root" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
instructions = root / ".agents" / "instructions"
instructions.mkdir(parents=True)
files = {
    root / "AGENTS.md": ("# Fixture\n", 10_000),
    instructions / "policy.instructions.md": (
        '---\ndescription: "Use when testing."\nname: fixture-policy\napplyTo: "**"\nalwaysApply: true\n---\n',
        60_000,
    ),
    instructions / "subject.reference.md": ("# Reference\n", 20_000),
    instructions / "conditional.md": ("---\nalwaysApply: false\n---\n", 10_000),
}
for path, (prefix, size) in files.items():
    encoded = prefix.encode()
    assert len(encoded) < size
    path.write_bytes(encoded + b"x" * (size - len(encoded)))
assert sum(path.stat().st_size for path in files) == 100_000
PY
  printf '%s' "$root"
}

run_validator() { # <root> <out-file> -> exit code
  local root="$1" out="$2" rc=0
  python3 "$VALIDATOR" "$root" >"$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

test_exact_cap_passes() {
  local root out rc
  root="$(make_fixture exact)"
  out="$WORK/exact.out"
  rc="$(run_validator "$root" "$out")"
  if [ "$rc" -eq 0 ] && grep -q '100000/100000 bytes' "$out"; then
    assert_pass "an exact 100000-byte instruction set passes"
  else
    assert_fail "an exact 100000-byte instruction set passes" "rc=$rc output=[$(cat "$out")]"
  fi
}

test_one_byte_over_fails() {
  local root out rc
  root="$(make_fixture over)"
  python3 - "$root/.agents/instructions/conditional.md" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("ab") as handle:
    handle.write(b"x")
PY
  out="$WORK/over.out"
  rc="$(run_validator "$root" "$out")"
  if [ "$rc" -eq 1 ] && grep -q '100001 bytes exceeds 100000 bytes' "$out"; then
    assert_pass "one byte over the cap fails and reports both totals"
  else
    assert_fail "one byte over the cap fails and reports both totals" "rc=$rc output=[$(cat "$out")]"
  fi
}

test_missing_agents_md_fails() {
  local root out rc
  root="$(make_fixture missing)"
  python3 -c 'import pathlib, sys; pathlib.Path(sys.argv[1]).unlink()' "$root/AGENTS.md"
  out="$WORK/missing.out"
  rc="$(run_validator "$root" "$out")"
  if [ "$rc" -eq 1 ] && grep -q 'missing files: ' "$out" && grep -q 'AGENTS.md' "$out"; then
    assert_pass "a repo without AGENTS.md fails and names the missing file"
  else
    assert_fail "a repo without AGENTS.md fails and names the missing file" "rc=$rc output=[$(cat "$out")]"
  fi
}

if [ ! -f "$VALIDATOR" ]; then
  assert_fail "the shared validator is present" "$VALIDATOR is missing"
  finish_tests
fi

section 1 "byte-cap boundary"
test_exact_cap_passes
test_one_byte_over_fails
test_missing_agents_md_fails

finish_tests
