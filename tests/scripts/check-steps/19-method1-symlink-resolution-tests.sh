#!/usr/bin/env bash
# Tests for check step 19 (method-one-symlink-resolution).
#
# The step's candidate list is derived from the deployed manifest rather than from
# an array inside the step, so these tests drive the step against fixture homes and
# assert its classification, plus structural guards that keep the drift from
# returning.
#
# Run with: bash tests/scripts/check-steps/19-method1-symlink-resolution-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
STEP_FILE="$REPO_ROOT/src/scripts/checks/check-steps/19-method1-symlink-resolution.sh"
WRITER="$REPO_ROOT/src/scripts/configs/write-method1-symlink-manifest.sh"
HOME_NIX="$REPO_ROOT/src/modules/home.nix"
readonly STEP_FILE WRITER HOME_NIX

# Nucleus user root for a fixture home, mirroring derive_nucleus_user_root.
fixture_user_root() {
  case "$(uname -s)" in
  Darwin) printf '%s\n' "$1/Library/Application Support/nucleus" ;;
  *) printf '%s\n' "$1/.local/share/nucleus" ;;
  esac
}

# Run the registered step function against FIXTURE_HOME/FIXTURE_REPO, capturing
# combined output to OUT_FILE and printing the exit status. The step is invoked
# through the real check-lib (sourced from this repository) so registration,
# step_number and skip_step behave as they do in a pipeline run; the fixture repo
# is what the step treats as the live repo root.
run_step() {
  local fixture_home="$1" fixture_repo="$2" out_file="$3" rc=0
  (
    cd "$fixture_repo" &&
      HOME="$fixture_home" NUCLEUS_REPO_ROOT="$fixture_repo" bash -c '
        set -euo pipefail
        . "$1/src/scripts/checks/check-lib.sh"
        . "$1/src/scripts/checks/check-steps/19-method1-symlink-resolution.sh"
        declare -A _ctx=([HAS_ARGS]=false [REPO_ROOT]="$2")
        run_method1_symlink_resolution _ctx
      ' _ "$REPO_ROOT" "$fixture_repo"
  ) >"$out_file" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# Build a fixture pair: a repo root (any directory outside /nix/store works) and a
# home with the given manifest lines.
make_fixture() {
  FIXTURE_REPO="$(mktemp -d)"
  FIXTURE_HOME="$(mktemp -d)"
  FIXTURE_MANIFEST="$(fixture_user_root "$FIXTURE_HOME")/method1-symlink-manifest.txt"
}

write_manifest() {
  mkdir -p "$(dirname "$FIXTURE_MANIFEST")"
  printf '%s\n' "$@" >"$FIXTURE_MANIFEST"
}

test_live_repo_target_passes() {
  local out rc=0
  make_fixture
  mkdir -p "$FIXTURE_REPO/src"
  ln -s "$FIXTURE_REPO/src" "$FIXTURE_HOME/live-link"
  write_manifest "# fixture" "$FIXTURE_HOME/live-link"
  rc="$(run_step "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_HOME/out.txt")"
  out="$(cat "$FIXTURE_HOME/out.txt")"
  if [ "$rc" -eq 0 ] && [ "${out#*verified 1 method-1 symlink}" != "$out" ]; then
    assert_pass "step 19 passes a link that resolves into the live repo root"
  else
    assert_fail "step 19 passes a link that resolves into the live repo root" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_HOME" "$FIXTURE_REPO"
}

test_store_snapshot_target_fails() {
  local out rc=0
  make_fixture
  ln -s "/nix/store/aaaa-source/src" "$FIXTURE_HOME/stale-link"
  write_manifest "# fixture" "$FIXTURE_HOME/stale-link"
  rc="$(run_step "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_HOME/out.txt")"
  out="$(cat "$FIXTURE_HOME/out.txt")"
  if [ "$rc" -eq 1 ] && [ "${out#*resolves to read-only store snapshot: /nix/store/aaaa-source/src}" != "$out" ]; then
    assert_pass "step 19 fails a link that resolves into a /nix/store/*-source snapshot"
  else
    assert_fail "step 19 fails a link that resolves into a /nix/store/*-source snapshot" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_HOME" "$FIXTURE_REPO"
}

test_walked_directory_is_audited() {
  local out rc=0
  make_fixture
  mkdir -p "$FIXTURE_HOME/tree"
  ln -s "/nix/store/bbbb-source/x" "$FIXTURE_HOME/tree/inside-link"
  write_manifest "# fixture" "$FIXTURE_HOME/tree"
  rc="$(run_step "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_HOME/out.txt")"
  out="$(cat "$FIXTURE_HOME/out.txt")"
  if [ "$rc" -eq 1 ] && [ "${out#*tree/inside-link}" != "$out" ]; then
    assert_pass "step 19 walks a directory entry one level and flags a store-snapshot link inside it"
  else
    assert_fail "step 19 walks a directory entry one level and flags a store-snapshot link inside it" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_HOME" "$FIXTURE_REPO"
}

test_non_symlink_is_ignored_and_store_target_warns() {
  local out rc=0
  make_fixture
  : >"$FIXTURE_HOME/plain-file"
  ln -s "/nix/store/cccc-home-manager-files/x" "$FIXTURE_HOME/hm-deployed"
  mkdir -p "$FIXTURE_REPO/src"
  ln -s "$FIXTURE_REPO/src" "$FIXTURE_HOME/live-link"
  write_manifest "# fixture" "$FIXTURE_HOME/plain-file" "$FIXTURE_HOME/hm-deployed" "$FIXTURE_HOME/live-link"
  rc="$(run_step "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_HOME/out.txt")"
  out="$(cat "$FIXTURE_HOME/out.txt")"
  if [ "$rc" -eq 0 ] &&
    [ "${out#*resolves into the Nix store: /nix/store/cccc-home-manager-files/x}" != "$out" ] &&
    [ "${out#*verified 2 method-1 symlink}" != "$out" ]; then
    assert_pass "step 19 ignores a non-symlink entry and warns about a non-snapshot store target"
  else
    assert_fail "step 19 ignores a non-symlink entry and warns about a non-snapshot store target" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_HOME" "$FIXTURE_REPO"
}

test_missing_manifest_skips() {
  local out rc=0
  make_fixture
  rc="$(run_step "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_HOME/out.txt")"
  out="$(cat "$FIXTURE_HOME/out.txt")"
  if [ "$rc" -eq 2 ] && [ "${out#*no deployed manifest}" != "$out" ]; then
    assert_pass "step 19 skips when the deployed manifest is absent"
  else
    assert_fail "step 19 skips when the deployed manifest is absent" "rc=$rc output=[$out]"
  fi
  rm -rf "$FIXTURE_HOME" "$FIXTURE_REPO"
}

# Structural guards: the drift this rewrite removes must not return.
test_step_has_no_restated_candidate_array() {
  if grep -q '_candidates=(' "$STEP_FILE"; then
    assert_fail "step 19 does not restate its candidates" "found a _candidates=( array"
  else
    assert_pass "step 19 does not restate its candidates"
  fi
}

test_manifest_roots_cover_the_deployed_trees() {
  local missing="" marker
  # shellcheck disable=SC2016 # reason: the markers are literal Nix source patterns, not shell expansions
  local -a markers=(
    method1ManifestPaths
    method1-symlink-manifest.txt
    write-method1-symlink-manifest
    '"${resolvedHomeDirectory}/.agents"'
    '"${resolvedHomeDirectory}/.cursor"'
    '"${resolvedHomeDirectory}/.config/opencode"'
    '"${resolvedHomeDirectory}/.pi/agent/settings.json"'
    '"${resolvedHomeDirectory}/data"'
    nucleusUserRoot
    isDarwin
  )
  for marker in "${markers[@]}"; do
    grep -qF "$marker" "$HOME_NIX" || missing="$missing [$marker]"
  done
  if [ -z "$missing" ]; then
    assert_pass "home.nix publishes a manifest covering the agent, cursor, editor, nucleus-root and data trees"
  else
    assert_fail "home.nix publishes a manifest covering the agent, cursor, editor, nucleus-root and data trees" "missing:$missing"
  fi
}

test_writer_exists() {
  if [ -f "$WRITER" ] && [ -x "$WRITER" ]; then
    assert_pass "the manifest writer script exists and is executable"
  else
    assert_fail "the manifest writer script exists and is executable" "$WRITER missing or not executable"
  fi
}

test_live_repo_target_passes
test_store_snapshot_target_fails
test_walked_directory_is_audited
test_non_symlink_is_ignored_and_store_target_warns
test_missing_manifest_skips
test_step_has_no_restated_candidate_array
test_manifest_roots_cover_the_deployed_trees
test_writer_exists
finish_tests
