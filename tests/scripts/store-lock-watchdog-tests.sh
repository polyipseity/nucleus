#!/usr/bin/env bash
# Tests: a stalled collection is reclaimed once, a collection that is using CPU
# or is too young is left alone, and the cooldown stops a second reclaim.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/bash-guard.sh
. "$REPO_ROOT/src/scripts/lib/bash-guard.sh"
bash_guard_require 5 1 test
init_test_state
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/store-lock.sh
. "$REPO_ROOT/src/scripts/lib/store-lock.sh"

_stub_dir="$(mktemp -d)"
cat >"$_stub_dir/ps" <<'STUB'
#!/usr/bin/env bash
cat "${PS_TABLE:?}"
STUB
chmod +x "$_stub_dir/ps"
export PATH="$_stub_dir:$PATH"

_victim=""
_start_victim() {
  sleep 300 &
  _victim=$!
}
_stop_victim() {
  if [ -n "$_victim" ] && kill -0 "$_victim" 2>/dev/null; then
    kill -TERM "$_victim" 2>/dev/null || true
    wait "$_victim" 2>/dev/null || true
  fi
}

_case_first_observation_never_reclaims() {
  local _state _out
  _state="$(mktemp -d)"
  _start_victim
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix store gc --max 1\n' "$_victim" "2:00:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  _out="$(store_lock_watchdog_tick "$_state" 3600 1 21600 2>&1)"
  if kill -0 "$_victim" 2>/dev/null; then
    assert_pass "the first sighting only records"
  else
    assert_fail "the first sighting only records" "victim was killed: $_out"
  fi
  if [ -f "$_state/$_victim" ]; then
    assert_pass "the observation is recorded"
  else
    assert_fail "the observation is recorded" "no state file in $_state"
  fi
  _stop_victim
}

_case_stalled_collection_is_reclaimed() {
  local _state _out
  _state="$(mktemp -d)"
  _start_victim
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix store gc --max 1\n' "$_victim" "2:00:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  _out="$(store_lock_watchdog_tick "$_state" 3600 1 21600 2>&1)"
  if ! kill -0 "$_victim" 2>/dev/null; then
    assert_pass "a stalled collection is killed"
  else
    assert_fail "a stalled collection is killed" "victim survived: $_out"
  fi
  case "$_out" in
  *"stalled for"*"no CPU progress"*) assert_pass "the reclaim is reported with its evidence" ;;
  *) assert_fail "the reclaim is reported with its evidence" "output: $_out" ;;
  esac
  read -r _ _ _slr_last_reclaim <"$_state/$_victim" || _slr_last_reclaim=0
  if [ "${_slr_last_reclaim:-0}" -gt 0 ]; then
    assert_pass "the cooldown starts"
  else
    assert_fail "the cooldown starts" "no per-pid reclaim record"
  fi
  _stop_victim
}

_case_cpu_progress_protects_a_long_collection() {
  local _state
  _state="$(mktemp -d)"
  _start_victim
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix-collect-garbage --delete-older-than 7d\n' "$_victim" "2:00:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  printf '%s %s %s nix-collect-garbage --delete-older-than 7d\n' "$_victim" "7:00:00" "1:12.00" >"$PS_TABLE"
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  if kill -0 "$_victim" 2>/dev/null; then
    assert_pass "a collection that is using CPU is left alone"
  else
    assert_fail "a collection that is using CPU is left alone" "victim was killed"
  fi
  _stop_victim
}

_case_young_collection_is_left_alone() {
  local _state
  _state="$(mktemp -d)"
  _start_victim
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix store gc --max 1\n' "$_victim" "0:05:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  if kill -0 "$_victim" 2>/dev/null; then
    assert_pass "a young collection is left alone"
  else
    assert_fail "a young collection is left alone" "victim was killed"
  fi
  _stop_victim
}

_case_cooldown_blocks_a_second_reclaim() {
  local _state _out
  _state="$(mktemp -d)"
  _start_victim
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix store gc --max 1\n' "$_victim" "2:00:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  if ! kill -0 "$_victim" 2>/dev/null; then
    assert_pass "the stalled collection is reclaimed once"
  else
    assert_fail "the stalled collection is reclaimed once" "victim survived"
  fi
  printf '%s %s %s nix store gc --max 1\n' "$_victim" "2:00:30" "0:00.00" >"$PS_TABLE"
  _out="$(store_lock_watchdog_tick "$_state" 3600 1 21600 2>&1)"
  case "$_out" in
  *"reclaim cooldown is active"*) assert_pass "the per-pid cooldown blocks another reclaim" ;;
  *) assert_fail "the per-pid cooldown blocks another reclaim" "output: $_out" ;;
  esac
  _stop_victim
}

_case_nix_store_gc_is_matched_and_dry_run_excluded() {
  local _state _out
  _state="$(mktemp -d)"
  _start_victim
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix-store --gc\n' "$_victim" "2:00:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  _out="$(store_lock_watchdog_tick "$_state" 3600 1 21600 2>&1)"
  if ! kill -0 "$_victim" 2>/dev/null; then
    assert_pass "nix-store --gc is reclaimed"
  else
    assert_fail "nix-store --gc is reclaimed" "victim survived: $_out"
  fi
  _stop_victim

  _start_victim
  printf '%s %s %s nix store gc --dry-run\n' "$_victim" "2:00:00" "0:00.00" >"$PS_TABLE"
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  if kill -0 "$_victim" 2>/dev/null; then
    assert_pass "dry-run collection is not reclaimed"
  else
    assert_fail "dry-run collection is not reclaimed" "victim was killed"
  fi
  _stop_victim
}

_case_two_stalled_pids_both_get_cooldown_records() {
  local _state _victim2 _out1 _out2
  _state="$(mktemp -d)"
  _start_victim
  sleep 300 &
  _victim2=$!
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix store gc --max 1\n%s %s %s nix-store --gc\n' "$_victim" "2:00:00" "0:00.00" "$_victim2" "2:00:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  _out1="$(store_lock_watchdog_tick "$_state" 3600 1 21600 2>&1)"
  case "$_out1" in
  *"$_victim"*stalled*) assert_pass "first stalled pid is reclaimed" ;;
  *) assert_fail "first stalled pid is reclaimed" "output: $_out1" ;;
  esac
  case "$_out1" in
  *"$_victim2"*stalled*) assert_pass "second stalled pid is reclaimed in same tick" ;;
  *) assert_fail "second stalled pid is reclaimed in same tick" "output: $_out1" ;;
  esac
  if [ -f "$_state/$_victim" ] && [ -f "$_state/$_victim2" ]; then
    assert_pass "both pids have reclaim records"
  else
    assert_fail "both pids have reclaim records" "missing state files in $_state"
  fi
  _stop_victim
  if kill -0 "$_victim2" 2>/dev/null; then
    kill -TERM "$_victim2" 2>/dev/null || true
    wait "$_victim2" 2>/dev/null || true
  fi
}

section "1" "stalled store-lock collection"
_case_first_observation_never_reclaims
_case_stalled_collection_is_reclaimed
_case_cpu_progress_protects_a_long_collection
_case_young_collection_is_left_alone
_case_cooldown_blocks_a_second_reclaim
_case_nix_store_gc_is_matched_and_dry_run_excluded
_case_two_stalled_pids_both_get_cooldown_records

finish_tests
