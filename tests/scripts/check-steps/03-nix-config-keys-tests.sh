#!/usr/bin/env bash
# Tests for the managed nix.conf key check (run_nix_conf_key_check, step 03).
#
# The managed config is deployed read-only to the daemon's nix.conf, and nix only
# warns about a name that is not a setting, so a key that never applies ships
# silently. These tests drive the real function through the real check-lib
# against throwaway repo roots, with one real `nix` parse of the whole file as the
# oracle. The live-repo case is host-conditional: the keys are judged only where
# the file is deployed, so on a host that never reads it the case asserts the
# applicability message.
#
# Run with: bash tests/scripts/check-steps/03-nix-config-keys-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
CONF_REL="src/modules/configs/nix/nix.custom.conf"
readonly REPO_ROOT CONF_REL

require_command nix "the managed config key check needs the real nix as its oracle"

# run_subcheck <fixture-repo> <out-file>: invoke the sub-check the way the runner
# does, with the context as its only argument, and print the exit status.
run_subcheck() { # <fixture-repo> <out-file>
  local rc=0
  (
    NUCLEUS_REPO_ROOT="$REPO_ROOT" NO_COLOR=1 bash -c '
      set -euo pipefail
      . "$1/src/scripts/checks/check-lib.sh"
      . "$1/src/scripts/checks/check-steps/03-nix-flake-eval.sh"
      declare -A _ctx=([HAS_ARGS]=false [REPO_ROOT]="$2")
      run_nix_conf_key_check _ctx
    ' _ "$REPO_ROOT" "$1"
  ) >"$2" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# make_fixture: a throwaway repo root holding only the managed config, so nothing
# in the live tree can satisfy a file the fixture forgot.
make_fixture() {
  FIXTURE_REPO="$(mktemp -d)"
  mkdir -p "$FIXTURE_REPO/src/modules/configs/nix"
}

write_conf() { # <line>...
  printf '%s\n' "$@" >"$FIXTURE_REPO/$CONF_REL"
}

# key_count <output>: the number of keys the sub-check reported parsing.
key_count() {
  printf '%s\n' "$1" | sed -n 's/.*passed (\([0-9][0-9]*\) keys).*/\1/p'
}

# contains <text> <needle>: substring test on captured output.
contains() { # <text> <needle>
  case "$1" in
  *"$2"*) return 0 ;;
  *) return 1 ;;
  esac
}

# run_applicability <out-file>: call the applicability gate the way the runner
# does, and print its exit status.
run_applicability() { # <out-file>
  local rc=0
  (
    NUCLEUS_REPO_ROOT="$REPO_ROOT" NO_COLOR=1 bash -c '
      set -euo pipefail
      . "$1/src/scripts/checks/check-lib.sh"
      . "$1/src/scripts/checks/check-steps/03-nix-flake-eval.sh"
      managed_nix_conf_check_applies
    ' _ "$REPO_ROOT"
  ) >"$1" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

test_live_config_matches_the_host_that_deploys_it() {
  local out_file rc=0 out count
  local undeployed_note="/etc/nix/nix.custom.conf is not deployed on this host"
  out_file="$(mktemp)"
  if [ -e /etc/nix/nix.custom.conf ]; then
    # The nix that consumes the file must know every key it declares. A parse
    # that found nothing would also report rc=0, so the count carries the
    # assertion that the live file was actually read and checked.
    rc="$(run_subcheck "$REPO_ROOT" "$out_file")"
    out="$(cat "$out_file")"
    count="$(key_count "$out")"
    if [ "$rc" -eq 0 ] && [ -n "$count" ] && [ "$count" -ge 10 ]; then
      assert_pass "the deployed live config passes and parses $count keys"
    else
      assert_fail "the deployed live config passes and parses $count keys" "rc=$rc count=[$count] output=[$out]"
    fi
  else
    # No nix on this host reads the file, so the host-correct expectation is the
    # applicability message, not a verdict from the wrong oracle.
    rc="$(run_applicability "$out_file")"
    out="$(cat "$out_file")"
    if [ "$rc" -eq 1 ] && contains "$out" "$undeployed_note"; then
      assert_pass "an undeployed managed config is not judged by this host's nix"
    else
      assert_fail "an undeployed managed config is not judged by this host's nix" "rc=$rc output=[$out]"
    fi
  fi
  rm -f "$out_file"
}

test_unknown_key_fails_and_is_named() {
  local out rc=0
  make_fixture
  write_conf "auto-optimise-store = true" "bogus-setting-name = 1"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && contains "$out" "$CONF_REL" && contains "$out" "bogus-setting-name"; then
    assert_pass "an unknown key fails and names the file and the key"
  else
    assert_fail "an unknown key fails and names the file and the key" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_comments_and_blank_lines_pass() {
  local out rc=0 count
  make_fixture
  write_conf "# the whole file is prose" "" "   " "# max-jobs = 2"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  count="$(key_count "$out")"
  if [ "$rc" -eq 0 ] && [ "$count" = "0" ]; then
    assert_pass "a file of comments and blank lines passes with no keys checked"
  else
    assert_fail "a file of comments and blank lines passes with no keys checked" "rc=$rc count=[$count] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_repeated_known_key_passes() {
  local out rc=0 count
  make_fixture
  write_conf "max-jobs = 2" "cores = 2" "cores = 2"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  count="$(key_count "$out")"
  if [ "$rc" -eq 0 ] && [ "$count" = "3" ]; then
    assert_pass "a repeated known key passes and both copies are checked"
  else
    assert_fail "a repeated known key passes and both copies are checked" "rc=$rc count=[$count] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_missing_managed_file_fails() {
  local out rc=0
  make_fixture
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && contains "$out" "managed nix config not found" && contains "$out" "$CONF_REL"; then
    assert_pass "a missing managed config fails instead of passing vacuously"
  else
    assert_fail "a missing managed config fails instead of passing vacuously" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_prose_naming_a_bogus_key_does_not_fail() {
  local out rc=0 count
  make_fixture
  write_conf \
    "# daemon-nice-level and daemon-ionice-level are not settings this nix reads" \
    "keep-outputs = true"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  count="$(key_count "$out")"
  if [ "$rc" -eq 0 ] && [ "$count" = "1" ]; then
    assert_pass "a bogus key named only in a comment is not read as a setting"
  else
    assert_fail "a bogus key named only in a comment is not read as a setting" "rc=$rc count=[$count] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_append_alias_passes() {
  local out rc=0 count
  make_fixture
  # `nix config show extra-substituters` fails while the config parser accepts the
  # line, so this case pins the parser as the oracle for append aliases.
  write_conf "extra-substituters = https://example.invalid"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  count="$(key_count "$out")"
  if [ "$rc" -eq 0 ] && [ "$count" = "1" ]; then
    assert_pass "an append alias the parser accepts passes"
  else
    assert_fail "an append alias the parser accepts passes" "rc=$rc count=[$count] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_alias_of_a_non_appendable_setting_fails() {
  local out rc=0
  make_fixture
  # The alias path must not degrade into "any extra- prefix is accepted".
  write_conf "extra-max-jobs = 2"
  rc="$(run_subcheck "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && contains "$out" "extra-max-jobs"; then
    assert_pass "an extra- alias of a setting nix does not append fails"
  else
    assert_fail "an extra- alias of a setting nix does not append fails" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

section 1 "the live managed config is read only where it is deployed"
test_live_config_matches_the_host_that_deploys_it

section 2 "an unknown setting fails and is named"
test_unknown_key_fails_and_is_named
test_alias_of_a_non_appendable_setting_fails
test_missing_managed_file_fails

section 3 "comments and non-setting lines are not read"
test_comments_and_blank_lines_pass
test_prose_naming_a_bogus_key_does_not_fail

section 4 "known settings and append aliases pass"
test_repeated_known_key_passes
test_append_alias_passes

finish_tests
