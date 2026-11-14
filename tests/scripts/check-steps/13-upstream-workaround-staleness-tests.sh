#!/usr/bin/env bash
# Tests for the upstream-workaround staleness sub-check
# (run_upstream_workaround_staleness, step 13).
#
# The sub-check is registered as `ctx` in _POLICY_DATA_CHECKS, so it is called
# with the context name as its only argument. It used to carry the files-style
# signature instead, which read $2 from a one-element argument list; under
# `set -u` that aborted the whole step before it checked a single path. These
# tests drive the real function through the real check-lib with a context, so the
# regression cannot return without a red run, and they keep a structural guard on
# the registration that the signature has to agree with.
#
# Run with: bash tests/scripts/check-steps/13-upstream-workaround-staleness-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
STEP_FILE="$REPO_ROOT/src/scripts/checks/check-steps/13-repo-policy-data.sh"
readonly REPO_ROOT STEP_FILE

REGISTRY_REL=".agents/instructions/upstream-workarounds.instructions.md"
readonly REGISTRY_REL

# run_subcheck <fixture-repo> <out-file>: invoke the sub-check the way the runner
# does, with the context as its only argument, and print the exit status.
run_subcheck() { # <fixture-repo> <out-file>
  local rc=0
  (
    bash -c '
      set -euo pipefail
      . "$1/src/scripts/checks/check-lib.sh"
      . "$1/src/scripts/checks/check-steps/13-repo-policy-data.sh"
      declare -A _ctx=([HAS_ARGS]=false [REPO_ROOT]="$2")
      run_upstream_workaround_staleness _ctx
    ' _ "$REPO_ROOT" "$1"
  ) >"$2" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# make_fixture: a throwaway repo root holding only the registry the sub-check
# reads, so nothing in the live tree can satisfy a path the fixture forgot.
make_fixture() {
  FIXTURE_REPO="$(mktemp -d)"
  mkdir -p "$FIXTURE_REPO/.agents/instructions" "$FIXTURE_REPO/src/modules"
}

write_registry() {
  printf '%s\n' "$@" >"$FIXTURE_REPO/$REGISTRY_REL"
}

test_listed_paths_that_exist_pass() {
  local out rc=0
  make_fixture
  : >"$FIXTURE_REPO/src/modules/present.nix"
  write_registry \
    "# registry" \
    "| W01 | src/modules/present.nix | probe | probe | probe |"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  # A ctx call also proves the signature: the old one died on the unset $2 here.
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "a registry whose paths all exist passes when called with a context"
  else
    assert_fail "a registry whose paths all exist passes when called with a context" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_missing_path_fails_and_names_it() {
  local out rc=0
  make_fixture
  write_registry \
    "# registry" \
    "| W01 | src/modules/present.nix | probe | probe | probe |"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && [ "${out#*references missing path: src/modules/present.nix}" != "$out" ]; then
    assert_pass "a registry row pointing at a missing path fails and names the path"
  else
    assert_fail "a registry row pointing at a missing path fails and names the path" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_trailing_punctuation_is_stripped_before_the_probe() {
  local out rc=0
  make_fixture
  : >"$FIXTURE_REPO/src/modules/present.nix"
  write_registry "| W01 | src/modules/present.nix. | probe | probe | probe |"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "a trailing period in the registry column does not fail the probe"
  else
    assert_fail "a trailing period in the registry column does not fail the probe" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_absent_registry_fails() {
  local out rc=0
  make_fixture
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && [ "${out#*upstream workarounds registry not found}" != "$out" ]; then
    assert_pass "an absent registry fails instead of passing vacuously"
  else
    assert_fail "an absent registry fails instead of passing vacuously" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

# Structural guards: the registration and the signature have to agree.
test_registered_as_ctx() {
  if grep -qF '"upstream workaround staleness|run_upstream_workaround_staleness|ctx"' "$STEP_FILE"; then
    assert_pass "the sub-check is registered with the ctx style"
  else
    assert_fail "the sub-check is registered with the ctx style" "no ctx registration in $STEP_FILE"
  fi
}

test_no_files_style_signature() {
  # Scoped to this function: the files-style sub-checks legitimately read $1 as
  # HAS_ARGS, so a whole-file grep would flag them instead.
  local body
  body="$(extract_func run_upstream_workaround_staleness "$STEP_FILE")"
  # shellcheck disable=SC2016 # reason: the literal source signature is the text being searched for
  if [ -z "$body" ]; then
    assert_fail "the sub-check defines a top-level function" "extract_func found nothing in $STEP_FILE"
  elif printf '%s' "$body" | grep -qF 'local _has_args="$1" _repo_root="$2"'; then
    assert_fail "the sub-check does not read the files-style arguments" "found a files-style signature in the function"
  else
    assert_pass "the sub-check does not read the files-style arguments"
  fi
}

test_live_registry_paths_all_exist() {
  local out rc=0 missing
  rc="$(run_subcheck "$REPO_ROOT" "$(mktemp)")"
  missing="$(grep -oE '(src|scripts|\.agents)/[A-Za-z0-9_./-]+' "$REPO_ROOT/$REGISTRY_REL" | sort -u | wc -l | tr -d ' ')"
  if [ "$rc" -eq 0 ] && [ "$missing" -ge 10 ]; then
    assert_pass "the live registry passes and lists $missing paths to check"
  else
    assert_fail "the live registry passes and lists $missing paths to check" "rc=$rc paths=$missing"
  fi
}

section 1 "the sub-check honours its ctx registration"
test_listed_paths_that_exist_pass
test_missing_path_fails_and_names_it
test_trailing_punctuation_is_stripped_before_the_probe
test_absent_registry_fails

section 2 "the registration and the signature agree"
test_registered_as_ctx
test_no_files_style_signature

section 3 "the live registry still resolves"
test_live_registry_paths_all_exist

finish_tests
