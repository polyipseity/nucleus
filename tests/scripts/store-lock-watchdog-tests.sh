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
  if [ -f "$_state/last-reclaim" ]; then
    assert_pass "the cooldown starts"
  else
    assert_fail "the cooldown starts" "no last-reclaim file"
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
  local _state _victim2
  _state="$(mktemp -d)"
  _start_victim
  PS_TABLE="$(mktemp)"
  printf '%s %s %s nix store gc --max 1\n' "$_victim" "2:00:00" "0:00.00" >"$PS_TABLE"
  export PS_TABLE
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  _stop_victim
  sleep 300 &
  _victim2=$!
  printf '%s %s %s nix store gc --max 1\n' "$_victim2" "2:00:00" "0:00.00" >"$PS_TABLE"
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  store_lock_watchdog_tick "$_state" 3600 1 21600 >/dev/null 2>&1
  if kill -0 "$_victim2" 2>/dev/null; then
    assert_pass "the cooldown stops a second reclaim"
  else
    assert_fail "the cooldown stops a second reclaim" "victim2 was killed"
  fi
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

finish_tests
