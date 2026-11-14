#!/usr/bin/env bash
# Tests for the managed nix.conf key check (run_nix_conf_key_check, step 03).
#
# The check applies where two conditions hold: the host's platform deploys the
# file (only macOS runs nix.enable = false, so only the MacBook file exists), and
# the running nix is the Determinate flavor that consumes it, because upstream Nix
# does not know settings the file declares. Nix only warns about a name that is
# not a setting, so a key that never applies ships silently. These tests drive the
# real function through the real check-lib against throwaway repo roots, with one
# real `nix` parse of the whole file as the oracle. The host is pinned per case
# through NUCLEUS_HOST and the nix flavor through a shim on PATH, so every branch
# runs on every host this suite runs on.
#
# Run with: bash tests/scripts/check-steps/03-nix-config-keys-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
CONF_REL="src/modules/configs/nix/nix.custom.MacBook.conf"

require_command nix "the managed config key check needs the real nix as its oracle"
require_command jq "resolving the host platform reads the host registry"

# The check resolves this host through the shared helper, so the suite resolves it
# the same way instead of repeating the uname mapping. Sourced after
# require_command so a missing prerequisite is still recorded by the tally.
export NUCLEUS_REPO_ROOT="$REPO_ROOT"
# shellcheck source=../../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# The flavor guard lives in the check itself: the live expectations call the
# check's own classifier, so the suite cannot hold a second copy of the decision.
# shellcheck source=../../../src/scripts/checks/check-steps/03-nix-flake-eval.sh
. "$REPO_ROOT/src/scripts/checks/check-steps/03-nix-flake-eval.sh"
readonly REPO_ROOT CONF_REL
HOST="$(resolve_nucleus_host)"
# The real nix, resolved before the shim can shadow it, and the directory the shim
# lives in. A case that must not depend on the installed flavor puts the shim first
# on PATH; the live case keeps the real nix so its expectation follows this host.
REAL_NIX="$(command -v nix)"
SHIM_DIR="$(mktemp -d)"
readonly HOST REAL_NIX SHIM_DIR

# The shim is the `nix` a flavor-pinned case runs. It answers the Determinate probe
# from SHIM_FLAVOR, records every call, and delegates everything else to the real
# nix, so a parse still runs the real parser and a case can prove whether one ran.
cat >"$SHIM_DIR/nix" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >>"${SHIM_LOG:?}"
if [ "$*" = "config show lazy-trees" ]; then
  case "${SHIM_FLAVOR:?}" in
  0) exit 0 ;;
  1) printf "error: could not find setting 'lazy-trees'\n" >&2; exit 1 ;;
  2) printf "error: opening lock file '/nix/var/nix/db/big-lock': Permission denied\n" >&2; exit 1 ;;
  3) printf "warning: unknown setting 'build-provenance-tags'\nerror: lazy-trees unavailable: Permission denied\n" >&2; exit 1 ;;
  *) printf 'shim: unknown flavor %s\n' "$SHIM_FLAVOR" >&2; exit 99 ;;
  esac
fi
exec "${REAL_NIX:?}" "$@"
SHIM
chmod +x "$SHIM_DIR/nix"

# run_subcheck <host> <fixture-repo> <out-file> <flavor> [nix-user-conf]: invoke the
# sub-check the way the runner does and print the exit status. The host is pinned
# through NUCLEUS_HOST. The flavor pins what the nix on PATH answers for the
# Determinate probe: 0 for the flavor that consumes the file, 1 for upstream Nix
# (the not-a-setting answer), 2 for a nix that cannot answer, 3 for a broken probe
# that also carries the runner's unrelated unknown-setting warning, and an empty
# value for the real nix. The optional user config supplies a setting warning that
# comes from a config source other than the managed file, which is how the CI
# runner's own nix.conf behaves.
run_subcheck() { # <host> <fixture-repo> <out-file> <flavor> [user-conf]
  local host="$1" fixture="$2" out_file="$3" flavor="$4" user_conf="${5:-}" rc=0
  (
    if [ -n "$user_conf" ]; then
      export NIX_USER_CONF_FILES="$user_conf"
    fi
    if [ -n "$flavor" ]; then
      export PATH="$SHIM_DIR:$PATH" SHIM_FLAVOR="$flavor" SHIM_LOG="$fixture/nix-calls.log" REAL_NIX
    fi
    NO_COLOR=1 NUCLEUS_HOST="$host" NUCLEUS_REPO_ROOT="$REPO_ROOT" bash -c '
      set -euo pipefail
      . "$1/src/scripts/checks/check-lib.sh"
      . "$1/src/scripts/checks/check-steps/03-nix-flake-eval.sh"
      declare -A _ctx=([HAS_ARGS]=false [REPO_ROOT]="$2")
      run_nix_conf_key_check _ctx
    ' _ "$REPO_ROOT" "$fixture"
  ) >"$out_file" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# make_fixture: a throwaway repo root holding only the managed config directory, so
# nothing in the live tree can satisfy a file the fixture forgot.
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

test_live_config_matches_the_host_that_deploys_it() {
  local out_file rc=0 out count live_state live_probe_err
  # One run-scoped TMPDIR artifact, read once below and never again: no cleanup
  # line for it.
  out_file="$(mktemp)"
  # The check's own classifier, called here first so this case maps the live
  # environment onto the same three-way expectation the check will act on: the
  # parse, the not-applicable skip, or the hard error for a probe that cannot
  # answer. The subshell below then runs the check against that environment.
  nix_conf_flavor_state "$HOST" live_state live_probe_err
  rc="$(run_subcheck "$HOST" "$REPO_ROOT" "$out_file" "")"
  out="$(cat "$out_file")"
  case "$live_state" in
  consumes)
    # The nix that consumes the deployed file must know every key it declares. A
    # parse that found nothing would also report rc=0, so the count carries the
    # assertion that the live file was actually read and checked.
    count="$(key_count "$out")"
    if [ "$rc" -eq 0 ] && [ -n "$count" ] && [ "$count" -ge 10 ]; then
      assert_pass "the live config on $HOST passes and parses $count keys"
    else
      assert_fail "the live config on $HOST passes and parses $count keys" "rc=$rc count=[$count] output=[$out]"
    fi
    ;;
  skip)
    # Nothing here consumes the file, so the host-correct expectation is the
    # not-applicable message, never a verdict from a nix that does not know it.
    if [ "$rc" -eq 0 ] && contains "$out" "no managed nix config judged on $HOST"; then
      assert_pass "$HOST has no nix that consumes the managed config, so it judges none"
    else
      assert_fail "$HOST has no nix that consumes the managed config, so it judges none" "rc=$rc output=[$out]"
    fi
    ;;
  broken)
    # A probe that cannot answer is a hard error, not a skip: the check must fail
    # with its stderr, and this case must expect exactly that failure instead of
    # reporting a misleading skip mismatch beside the real one. The stderr match
    # pins that the classifier and the check saw the same failure.
    if [ "$rc" -eq 1 ] && contains "$out" "$CONF_REL" &&
      contains "$out" "could not report whether it knows the managed settings" &&
      { [ -z "$live_probe_err" ] || contains "$out" "$live_probe_err"; }; then
      assert_pass "a live probe that cannot answer fails the check and the case expects it"
    else
      assert_fail "a live probe that cannot answer fails the check and the case expects it" "rc=$rc probe=[$live_probe_err] output=[$out]"
    fi
    ;;
  *)
    assert_fail "the flavor classifier returned a recognised state" "state=[$live_state]"
    ;;
  esac
}

test_host_that_deploys_no_config_skips_without_reading_one() {
  local out rc=0 calls=""
  make_fixture
  # The consuming flavor is pinned, so the host clause alone must skip; without the
  # pin an upstream runner would skip in the flavor clause and leave the host clause
  # untested. An empty call log proves the check returned before probing, and the
  # fixture holds no config, so a read would fail with "managed nix config not
  # found" as well.
  rc="$(run_subcheck NixOS "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ -f "$FIXTURE_REPO/nix-calls.log" ]; then
    calls="$(cat "$FIXTURE_REPO/nix-calls.log")"
  fi
  if [ "$rc" -eq 0 ] && contains "$out" "no managed nix config judged on NixOS" &&
    [ -z "$calls" ] && ! contains "$out" "not found"; then
    assert_pass "a host that deploys no managed config skips without probing or reading"
  else
    assert_fail "a host that deploys no managed config skips without probing or reading" "rc=$rc calls=[$calls] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_darwin_host_under_upstream_nix_skips() {
  local out calls rc=0
  make_fixture
  # The CI shape: a macOS runner resolves to MacBook but installs upstream Nix,
  # which does not know settings the file declares (eval-cores, lazy-trees). The
  # shim reports that flavor and records every nix call. No config is written, so a
  # parse would also fail loudly; the call log proves none ran at all.
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 1)"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  # No log means no nix call at all, which the assertion must report as a failure
  # rather than let an unreadable file abort the suite.
  calls="(no nix call recorded)"
  if [ -f "$FIXTURE_REPO/nix-calls.log" ]; then
    calls="$(cat "$FIXTURE_REPO/nix-calls.log")"
  fi
  if [ "$rc" -eq 0 ] && contains "$out" "no managed nix config judged on MacBook" &&
    contains "$out" "could not find setting" && ! contains "$out" "passed (" &&
    [ "$calls" = "config show lazy-trees" ]; then
    assert_pass "a darwin host under upstream nix skips, naming the probe answer"
  else
    assert_fail "a darwin host under upstream nix skips, naming the probe answer" "rc=$rc calls=[$calls] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_probe_that_cannot_answer_fails_the_check() {
  local out calls="" rc=0
  make_fixture
  # A nix that fails the probe for a reason other than not knowing the setting is
  # broken, not inapplicable: the check must fail with that stderr rather than switch
  # itself off. The fixture holds no config, so a parse would fail too, and the call
  # log proves none ran.
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 2)"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ -f "$FIXTURE_REPO/nix-calls.log" ]; then
    calls="$(cat "$FIXTURE_REPO/nix-calls.log")"
  fi
  if [ "$rc" -eq 1 ] && contains "$out" "$CONF_REL" && contains "$out" "Permission denied" &&
    [ "$calls" = "config show lazy-trees" ]; then
    assert_pass "a probe that cannot answer fails the check with its stderr"
  else
    assert_fail "a probe that cannot answer fails the check with its stderr" "rc=$rc calls=[$calls] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_unrelated_unknown_setting_warning_does_not_classify_the_probe() {
  local out rc=0 calls=""
  make_fixture
  # The runner's own nix.conf carries a setting this nix does not know and warns
  # about it on every run (`.github/workflows/ci.yml:82`), so the probe's stderr
  # can hold an `unknown setting` warning about another name before its real
  # failure. Only the classified phrase with the quoted probe name inline counts
  # as the upstream answer; anything else is a broken probe that must fail loudly
  # instead of switching the check off as not-applicable.
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 3)"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ -f "$FIXTURE_REPO/nix-calls.log" ]; then
    calls="$(cat "$FIXTURE_REPO/nix-calls.log")"
  fi
  if [ "$rc" -eq 1 ] && contains "$out" "$CONF_REL" &&
    contains "$out" "could not report whether it knows the managed settings" &&
    contains "$out" "build-provenance-tags" && ! contains "$out" "no managed nix config judged" &&
    [ "$calls" = "config show lazy-trees" ]; then
    assert_pass "an unrelated unknown-setting warning does not classify a broken probe as upstream"
  else
    assert_fail "an unrelated unknown-setting warning does not classify a broken probe as upstream" "rc=$rc calls=[$calls] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_unknown_key_fails_and_is_named() {
  local out rc=0
  make_fixture
  write_conf "auto-optimise-store = true" "bogus-setting-name = 1"
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
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
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
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
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
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
  # The guards pass, so the check reaches the tree and finds it incomplete.
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
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
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
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
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
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
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0)"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  if [ "$rc" -eq 1 ] && contains "$out" "extra-max-jobs"; then
    assert_pass "an extra- alias of a setting nix does not append fails"
  else
    assert_fail "an extra- alias of a setting nix does not append fails" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

test_warning_from_another_config_source_is_not_a_file_defect() {
  local out rc=0 count user_conf
  make_fixture
  write_conf "max-jobs = 2"
  user_conf="$FIXTURE_REPO/user.conf"
  # A warning about a name this file never declares. Nix parses every config source
  # it reads, so a source outside the managed file reaches this check's stderr; the
  # CI installer does exactly that with a setting upstream Nix does not know.
  printf 'outside-scope-setting = 1\n' >"$user_conf"
  rc="$(run_subcheck MacBook "$FIXTURE_REPO" "$FIXTURE_REPO/out.txt" 0 "$user_conf")"
  out="$(cat "$FIXTURE_REPO/out.txt")"
  count="$(key_count "$out")"
  if [ "$rc" -eq 0 ] && [ "$count" = "1" ] && contains "$out" "unattributed" &&
    contains "$out" "outside-scope-setting" && ! contains "$out" "$CONF_REL"; then
    assert_pass "a warning about a name the file never declares is reported unattributed"
  else
    assert_fail "a warning about a name the file never declares is reported unattributed" "rc=$rc count=[$count] output=[$out]"
  fi
  rm -rf "$FIXTURE_REPO"
}

section 1 "the managed config is judged only under a consuming nix that can answer"
test_live_config_matches_the_host_that_deploys_it
test_host_that_deploys_no_config_skips_without_reading_one
test_darwin_host_under_upstream_nix_skips
test_probe_that_cannot_answer_fails_the_check
test_unrelated_unknown_setting_warning_does_not_classify_the_probe

section 2 "an unknown setting the file declares fails and is named"
test_unknown_key_fails_and_is_named
test_alias_of_a_non_appendable_setting_fails
test_missing_managed_file_fails

section 3 "comments and non-setting lines are not read"
test_comments_and_blank_lines_pass
test_prose_naming_a_bogus_key_does_not_fail

section 4 "known settings and append aliases pass"
test_repeated_known_key_passes
test_append_alias_passes

section 5 "a warning the file does not own is not a file defect"
test_warning_from_another_config_source_is_not_a_file_defect

rm -rf "$SHIM_DIR"
finish_tests
