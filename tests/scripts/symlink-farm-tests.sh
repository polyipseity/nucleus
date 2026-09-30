#!/usr/bin/env bash
# Tests for the /usr/local/bin symlink farm convergence in
# src/hosts/MacBook/scripts/macos-symlink-farm.sh.
#
# Two defects this guards. The reported count was the number of writes, printed
# under the label "active symlinks", so a converged farm announced 0 active
# links while every link was in place. And a link whose text matched the
# expected store path was accepted without resolving it, so a mapping pointing at
# a GC'd store path stayed forever.
#
# WHY: grep instead of parsing. The behaviour under test is which branch of the
# convergence loop runs for a given on-disk state; there is no Nix evaluation to
# observe, and the script's contract is its effect on files plus its summary
# line. FARM_DIR redirects the farm to a temp dir so the suite never touches
# /usr/local/bin.
#
# Run with: bash tests/scripts/symlink-farm-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT
FARM_SH="$REPO_ROOT/src/hosts/MacBook/scripts/macos-symlink-farm.sh"
readonly FARM_SH

require_command python3 "python3 resolves the fixture store paths"
require_command bash "bash is a symlink-farm fixture target"
require_command sh "sh is a symlink-farm fixture target"

# Targets must be real, resolvable /nix/store paths.  The script resolves each
# link with -e, and the GC sweep only reaps links whose target begins with
# /nix/store/, so a target reached through /run/current-system or /usr/bin would
# pass the existence test and then fail the GC's prefix test.  realpath is what
# puts the host's own toolchain back on its true store path, and resolving at
# runtime keeps the suite portable instead of pinning one host's store hashes.
#
# The resolver returns 1 instead of exiting: an exit here runs inside a command
# substitution, so it would kill the suite before finish_tests and leave the
# runner with no tally.  Assigning the store paths from this function in the
# suite's own shell keeps assert_fail and finish_tests reachable.
STORE_A=""
STORE_B=""
_fixture_error=""
resolve_fixture_targets() {
  local _bin _real
  for _bin in bash sh; do
    if ! _real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(command -v "$_bin")")"; then
      _fixture_error="${_bin}: realpath failed for $(command -v "$_bin")"
      return 1
    fi
    case "$_real" in
    /nix/store/*) ;;
    *)
      _fixture_error="${_bin} must resolve into /nix/store, got: ${_real}"
      return 1
      ;;
    esac
    case "$_bin" in
    bash) STORE_A="$_real" ;;
    sh) STORE_B="$_real" ;;
    esac
  done
}

if ! resolve_fixture_targets; then
  assert_fail "symlink-farm fixtures resolve into /nix/store" "$_fixture_error"
  finish_tests
fi
readonly STORE_A STORE_B

# The script writes only inside FARM_DIR and the log path it is handed, so a
# temp farm is enough isolation.
make_farm() {
  mktemp -d
}

test_fresh_farm_creates_links_and_counts_them_active() {
  local _farm _rc
  _farm="$(make_farm)"
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool $STORE_B->other" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "a fresh farm creates every link and counts them active" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif [ ! -L "$_farm/tool" ] || [ ! -L "$_farm/other" ]; then
    assert_fail "a fresh farm creates every link and counts them active" "links missing: $(ls -A "$_farm")"
  elif ! grep -q '2 active symlinks' "$_farm/out"; then
    assert_fail "a fresh farm creates every link and counts them active" "output=[$(cat "$_farm/out")]"
  else
    assert_pass "a fresh farm creates every link and counts them active"
  fi
  rm -rf "$_farm"
}

# The regression: the second run writes nothing, and the old message reported
# that write count as "0 active symlinks".
test_converged_farm_reports_links_as_active_not_zero() {
  local _farm _rc
  _farm="$(make_farm)"
  FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool $STORE_B->other" "$_farm/log" >/dev/null 2>&1
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool $STORE_B->other" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "a converged farm reports its links as active, not as zero" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif grep -q '0 active symlinks' "$_farm/out"; then
    assert_fail "a converged farm reports its links as active, not as zero" "output=[$(cat "$_farm/out")]"
  elif ! grep -q '2 active symlinks' "$_farm/out"; then
    assert_fail "a converged farm reports its links as active, not as zero" "output=[$(cat "$_farm/out")]"
  else
    assert_pass "a converged farm reports its links as active, not as zero"
  fi
  rm -rf "$_farm"
}

test_changed_target_is_relinked() {
  local _farm _rc
  _farm="$(make_farm)"
  FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool" "$_farm/log" >/dev/null 2>&1
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$STORE_B->tool" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "a changed target is relinked" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif [ "$(readlink "$_farm/tool")" != "$STORE_B" ]; then
    assert_fail "a changed target is relinked" "readlink=[$(readlink "$_farm/tool")]"
  else
    assert_pass "a changed target is relinked"
  fi
  rm -rf "$_farm"
}

# GC only touches /nix/store links that fell out of the entry list.
test_unlisted_store_link_is_gc_and_foreign_link_is_kept() {
  local _farm _rc
  _farm="$(make_farm)"
  FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool $STORE_B->stale" "$_farm/log" >/dev/null 2>&1
  ln -s /usr/local/some-tool "$_farm/foreign"
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "an unlisted store link is GC'd and a non-store link is kept" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif [ -L "$_farm/stale" ]; then
    assert_fail "an unlisted store link is GC'd and a non-store link is kept" "stale link survived"
  elif [ ! -L "$_farm/foreign" ]; then
    assert_fail "an unlisted store link is GC'd and a non-store link is kept" "foreign link was removed"
  elif ! grep -q "1 GC'd" "$_farm/out"; then
    assert_fail "an unlisted store link is GC'd and a non-store link is kept" "output=[$(cat "$_farm/out")]"
  else
    assert_pass "an unlisted store link is GC'd and a non-store link is kept"
  fi
  rm -rf "$_farm"
}

# A link whose text matches but whose store path is gone reads as correct to a
# plain string comparison, which is how a dead mapping survived every apply.
test_dangling_link_is_reported_and_not_counted_active() {
  local _farm _rc
  _farm="$(make_farm)"
  # A store path that cannot exist: the shape a GC'd derivation leaves behind.
  # The link text matches the mapping exactly, so only resolving it reveals the
  # target is gone.
  local _gone="/nix/store/00000000000000000000000000000000-nucleus-test-gone/bin/gone"
  ln -s "$_gone" "$_farm/tool"
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$_gone->tool" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "a dangling link is reported and not counted active" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif ! grep -q '1 dangling' "$_farm/out"; then
    assert_fail "a dangling link is reported and not counted active" "output=[$(cat "$_farm/out")]"
  elif grep -q '1 active symlinks' "$_farm/out"; then
    assert_fail "a dangling link is reported and not counted active" "dangling link counted active: output=[$(cat "$_farm/out")]"
  else
    assert_pass "a dangling link is reported and not counted active"
  fi
  rm -rf "$_farm"
}

test_marker_file_is_never_gc() {
  local _farm _rc
  _farm="$(make_farm)"
  FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool" "$_farm/log" >/dev/null 2>&1
  touch "$_farm/.nucleus-symlink-farm"
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "the farm marker file is never GC'd" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif [ ! -f "$_farm/.nucleus-symlink-farm" ]; then
    assert_fail "the farm marker file is never GC'd" "marker was removed"
  elif ! grep -q "0 GC'd" "$_farm/out"; then
    assert_fail "the farm marker file is never GC'd" "output=[$(cat "$_farm/out")]"
  else
    assert_pass "the farm marker file is never GC'd"
  fi
  rm -rf "$_farm"
}

# The create loop removes whatever sits at the link path before symlinking, so a
# regular file occupying a farm name is replaced.  Only the GC sweep guards on -L.
# Recorded here because the script's header comment claims neither loop touches
# regular files; that claim is wrong for the create path and this test pins the
# behaviour that actually ships.
test_regular_file_at_a_farm_name_is_replaced() {
  local _farm _rc
  _farm="$(make_farm)"
  printf '#!/bin/sh\n' >"$_farm/tool"
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "a regular file at a farm name is replaced by the symlink" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif [ ! -L "$_farm/tool" ]; then
    assert_fail "a regular file at a farm name is replaced by the symlink" "still a regular file: $(ls -la "$_farm/tool")"
  else
    assert_pass "a regular file at a farm name is replaced by the symlink"
  fi
  rm -rf "$_farm"
}

# A regular file the farm does not manage must survive: the GC sweep is guarded
# on -L, so it must not remove non-symlinks even when they sit in the farm dir.
test_unmanaged_regular_file_survives_gc() {
  local _farm _rc
  _farm="$(make_farm)"
  printf '#!/bin/sh\n' >"$_farm/unmanaged"
  _rc="$(
    FARM_DIR="$_farm" "$FARM_SH" "$STORE_A->tool" "$_farm/log" >"$_farm/out" 2>&1
    printf '%s' $?
  )"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "an unmanaged regular file survives the GC sweep" "rc=$_rc output=[$(cat "$_farm/out")]"
  elif [ ! -f "$_farm/unmanaged" ]; then
    assert_fail "an unmanaged regular file survives the GC sweep" "file was removed"
  else
    assert_pass "an unmanaged regular file survives the GC sweep"
  fi
  rm -rf "$_farm"
}

test_fresh_farm_creates_links_and_counts_them_active
test_converged_farm_reports_links_as_active_not_zero
test_changed_target_is_relinked
test_unlisted_store_link_is_gc_and_foreign_link_is_kept
test_dangling_link_is_reported_and_not_counted_active
test_marker_file_is_never_gc
test_regular_file_at_a_farm_name_is_replaced
test_unmanaged_regular_file_survives_gc

finish_tests
