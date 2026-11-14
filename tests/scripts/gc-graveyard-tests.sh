#!/usr/bin/env bash
# Pins the nucleus-gc graveyard report: the path it resolves, the entry count,
# the recursive byte total, the oldest entry, and that it deletes nothing.
#
# The report is what makes the persistent rip graveyard observable, so the count
# has to come from the resolved path rather than from a constant. Each case
# therefore seeds a graveyard whose oldest entry is a known file, and the
# fallback cases point NUCLEUS_USER_ROOT at a temp root so a report that only
# echoed the variable could not pass.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

ensure_safe_rm_env
init_test_state

GC_SH="$SCRIPT_DIR/../../scripts/gc.sh"

require_command find "graveyard entries are counted with find"
require_command stat "graveyard entry mtimes are read with stat"
require_command du "graveyard bytes are totalled with du"
require_command cut "du output is split with cut"
require_command uname "the portable stat flavor is selected with uname"

# seed_graveyard DIR: two top-level files and one top-level directory, each with
# a distinct mtime. oldest.txt is the oldest entry, so the report's choice is
# unambiguous.
seed_graveyard() { # <dir>
  local _gy="$1"
  mkdir -p "$_gy/nested"
  printf 'newer\n' >"$_gy/newer.txt"
  printf 'oldest\n' >"$_gy/oldest.txt"
  printf 'deep\n' >"$_gy/nested/deep.txt"
  # Directory mtimes move when a child is created, so the directory is stamped last.
  touch -t 202001010000 "$_gy/oldest.txt"
  touch -t 202401010000 "$_gy/newer.txt"
  touch -t 202301010000 "$_gy/nested"
}

# ---- Test A: RIP_GRAVEYARD wins over the nucleus USER root ----

test_rip_graveyard_env_wins() {
  local work gy out rc=0
  work="$(mktemp -d)"
  gy="$work/graveyard"
  seed_graveyard "$gy"

  # NUCLEUS_USER_ROOT points somewhere else, so a report that ignored
  # RIP_GRAVEYARD would print the other path and count nothing.
  out="$(RIP_GRAVEYARD="$gy" NUCLEUS_USER_ROOT="$work/other-root" bash "$GC_SH" graveyard 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    assert_pass "graveyard report exits 0"
  else
    assert_fail "graveyard-exit" "rc=$rc output: $out"
  fi
  if grep -qF "graveyard: $gy" <<<"$out"; then
    assert_pass "graveyard report names the RIP_GRAVEYARD path"
  else
    assert_fail "graveyard-path" "output: $out"
  fi
  if grep -q 'entries: 3' <<<"$out"; then
    assert_pass "graveyard report counts the two files and the directory"
  else
    assert_fail "graveyard-count" "output: $out"
  fi
  if grep -qE 'bytes: [1-9][0-9]*' <<<"$out"; then
    assert_pass "graveyard report totals the bytes recursively"
  else
    assert_fail "graveyard-bytes" "output: $out"
  fi
  if grep -qF "oldest: $gy/oldest.txt" <<<"$out"; then
    assert_pass "graveyard report names the oldest entry"
  else
    assert_fail "graveyard-oldest" "output: $out"
  fi
  if [ -f "$gy/newer.txt" ] && [ -f "$gy/oldest.txt" ] && [ -f "$gy/nested/deep.txt" ]; then
    assert_pass "graveyard report deletes nothing"
  else
    assert_fail "graveyard-no-delete" "entries are missing from $gy"
  fi
  rm -rf "$work"
}

# ---- Test B: an unset RIP_GRAVEYARD falls back to the nucleus USER root ----

test_fallback_root_reports_missing_dir() {
  local root out rc=0
  root="$(mktemp -d)"

  out="$(unset RIP_GRAVEYARD && NUCLEUS_USER_ROOT="$root" bash "$GC_SH" graveyard 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ] && ! grep -q 'error:' <<<"$out"; then
    assert_pass "graveyard report of a missing directory exits 0 without an error"
  else
    assert_fail "graveyard-missing" "rc=$rc output: $out"
  fi
  if grep -qF "graveyard: $root/state/rip/graveyard" <<<"$out"; then
    assert_pass "graveyard report falls back to <USER root>/state/rip/graveyard"
  else
    assert_fail "graveyard-fallback-path" "output: $out"
  fi
  if grep -q 'entries: 0' <<<"$out"; then
    assert_pass "graveyard report counts a missing directory as zero entries"
  else
    assert_fail "graveyard-fallback-count" "output: $out"
  fi
  rm -rf "$root"
}

# ---- Test C: the fallback reads the directory it resolves ----

test_fallback_root_counts_entries() {
  local root gy out rc=0
  root="$(mktemp -d)"
  gy="$root/state/rip/graveyard"
  seed_graveyard "$gy"

  out="$(unset RIP_GRAVEYARD && NUCLEUS_USER_ROOT="$root" bash "$GC_SH" graveyard 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ] && grep -qF "graveyard: $gy" <<<"$out" && grep -q 'entries: 3' <<<"$out"; then
    assert_pass "graveyard report counts the entries under the fallback root"
  else
    assert_fail "graveyard-fallback-entries" "rc=$rc output: $out"
  fi
  rm -rf "$root"
}

section 1 "gc graveyard tests"
echo ""

test_rip_graveyard_env_wins
test_fallback_root_reports_missing_dir
test_fallback_root_counts_entries

finish_tests
