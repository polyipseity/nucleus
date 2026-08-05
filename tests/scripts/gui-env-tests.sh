#!/usr/bin/env bash
# Tests for src/scripts/hosts/MacBook/macos-set-gui-env.sh — the login
# LaunchAgent that propagates catalog env vars into the macOS GUI launchd
# domain.
#
# Pins the regressions fixed in the gui-env saga:
#   1. Empty prepend argv (managedPaths.prepend is empty) must NOT kill the
#      agent: `${1:?}` died under `set -eu`, so GUI apps got no catalog vars
#      after reboot until a nucleus-apply ran.
#   2. PATH composition must never produce a leading/trailing colon (empty
#      PATH entry = cwd).
#   3. Stale managed entries are stripped before the managed dirs are re-added.
#
# The real script calls launchctl via $GUI_ENV_LAUNCHCTL (default
# /bin/launchctl); tests point it at a recording stub.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

SCRIPT_UNDER_TEST="$SCRIPT_DIR/../../src/scripts/hosts/MacBook/macos-set-gui-env.sh"
# Absolute interpreter path: tests override PATH (e.g. the all-managed case),
# which would otherwise hide a bare `bash` lookup.
BASH_BIN="$(command -v bash)"

# ── Setup / teardown ──────────────────────────────────────────────────────
TESTDIR=""
LAUNCHCTL_STUB=""
LAUNCHCTL_LOG=""

setup() {
  TESTDIR="$(mktemp -d)"
  LAUNCHCTL_STUB="$TESTDIR/launchctl"
  LAUNCHCTL_LOG="$TESTDIR/launchctl.log"
  # Write the stub with printf so $BASH_BIN expands here (heredoc escaping of
  # `\$*`/`\$LAUNCHCTL_LOG` would otherwise make the shebang literal).  `echo`
  # not `printf %s\n`: an unquoted `\n` has its backslash stripped at bash
  # parse time, so printf would receive format `%sn` and append a literal `n`.
  # shellcheck disable=SC2016 # reason: the format is literal stub-source text; $* and $LAUNCHCTL_LOG must reach the stub file unexpanded
  printf '#!%s\necho "$*" >> "$LAUNCHCTL_LOG"\n' "$BASH_BIN" > "$LAUNCHCTL_STUB"
  chmod +x "$LAUNCHCTL_STUB"
}

teardown() {
  rm -rf -- "$TESTDIR"
}

# run_agent <prepend> <append> <dedup-set> <all-vars> [extra PATH...]
# Records the full launchctl command lines into a file; returns agent exit code.
# The final PATH given to the agent is: extra args + a default non-managed tail.
run_agent() {
  local _prepend="$1" _append="$2" _dedup="$3" _all_vars="$4"; shift 4
  local _extra_path
  _extra_path="$(IFS=:; printf '%s' "$*")"
  if [ -n "$_extra_path" ]; then
    _extra_path="$_extra_path:"
  fi
  GUI_ENV_LAUNCHCTL="$LAUNCHCTL_STUB" \
    LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    PATH="${_extra_path}/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BASH_BIN" "$SCRIPT_UNDER_TEST" "$_prepend" "$_append" "$_dedup" "$_all_vars"
}

last_setenv_path() {
  grep '^setenv PATH ' "$LAUNCHCTL_LOG" | tail -1 | sed 's/^setenv PATH //'
}

# ── Test: empty prepend arg is tolerated ──────────────────────────────────
# WHY: managedPaths.prepend is currently empty, and launchd passes the argv
# literally — `${1:?}` used to abort the whole agent at login with exit 1.
test_empty_prepend() {
  setup
  local _append="/Users/t/.bun/bin:/Users/t/.cargo/bin"
  if run_agent "" "$_append" "$_append" "true"; then
    assert_pass "Empty prepend: agent exits 0"
  else
    assert_fail "Empty prepend: agent exits 0" "agent returned non-zero"
  fi
  local _path
  _path="$(last_setenv_path)"
  case "$_path" in
    ":*"*) assert_fail "Empty prepend: no leading colon" "PATH starts with colon: $_path" ;;
    *) assert_pass "Empty prepend: no leading colon" ;;
  esac
  case "$_path" in
    *":$_append") assert_pass "Empty prepend: managed dirs appended" ;;
    *) assert_fail "Empty prepend: managed dirs appended" "PATH='$_path'" ;;
  esac
  teardown
}

# ── Test: prepend fragment appears first, no double colons ────────────────
# WHY: when prepend is non-empty it must come first, joined by single colons.
test_prepend_fragment() {
  setup
  local _append="/Users/t/.cargo/bin"
  local _prepend="/opt/managed/bin"
  if run_agent "$_prepend" "$_append" "$_append" "true"; then
    assert_pass "Prepend fragment: agent exits 0"
  else
    assert_fail "Prepend fragment: agent exits 0" "agent returned non-zero"
  fi
  local _path
  _path="$(last_setenv_path)"
  case "$_path" in
    "$_prepend:"*) assert_pass "Prepend fragment: prepend is first" ;;
    *) assert_fail "Prepend fragment: prepend is first" "PATH='$_path'" ;;
  esac
  case "$_path" in
    *"::"*) assert_fail "Prepend fragment: no double colon" "PATH='$_path'" ;;
    *) assert_pass "Prepend fragment: no double colon" ;;
  esac
  teardown
}

# ── Test: managed entries stripped from PATH before re-add ────────────────
# WHY: PATH accumulates the managed dirs from previous launches (nix-darwin
# prepends); they must be removed from the middle so the final PATH has no
# duplicates.
test_dedup_strips_managed() {
  setup
  local _append="/Users/t/.bun/bin:/Users/t/.cargo/bin"
  # Simulate a stale PATH where the managed dirs are already present inline.
  if run_agent "" "$_append" "$_append" "true" \
      "/Users/t/.cargo/bin:/usr/local/bin:/Users/t/.bun/bin"; then
    assert_pass "Dedup: agent exits 0"
  else
    assert_fail "Dedup: agent exits 0" "agent returned non-zero"
  fi
  local _path
  _path="$(last_setenv_path)"
  local _bun_count _usrlocal_count
  _bun_count="$(printf '%s' "$_path" | grep -o '/Users/t/.bun/bin' | wc -l | tr -d ' ')"
  if [ "$_bun_count" -eq 1 ]; then
    assert_pass "Dedup: managed dir appears exactly once"
  else
    assert_fail "Dedup: managed dir appears exactly once" "count=$_bun_count PATH='$_path'"
  fi
  _usrlocal_count="$(printf '%s' "$_path" | grep -o '/usr/local/bin' | wc -l | tr -d ' ')"
  if [ "$_usrlocal_count" -eq 1 ]; then
    assert_pass "Dedup: non-managed dir retained exactly once"
  else
    assert_fail "Dedup: non-managed dir retained exactly once" "count=$_usrlocal_count PATH='$_path'"
  fi
  case "$_path" in
    *"::"*) assert_fail "Dedup: no double colon" "PATH='$_path'" ;;
    *) assert_pass "Dedup: no double colon" ;;
  esac
  teardown
}

# ── Test: all-vars block is executed ──────────────────────────────────────
# WHY: the agent must eval the catalog block (EDITOR, OLLAMA_HOST, ...) — not
# just PATH — or GUI apps still miss non-PATH vars after reboot.
test_all_vars_block() {
  setup
  local _marker="$TESTDIR/all-vars-ran"
  local _block="touch '$_marker'"
  if run_agent "" "" "" "$_block"; then
    assert_pass "All-vars block: agent exits 0"
  else
    assert_fail "All-vars block: agent exits 0" "agent returned non-zero"
  fi
  if [ -f "$_marker" ]; then
    assert_pass "All-vars block: block executed"
  else
    assert_fail "All-vars block: block executed" "marker not created"
  fi
  teardown
}

# ── Test: empty PATH composition stays valid ──────────────────────────────
# WHY: when every PATH entry is managed, cleaned is empty; the composed value
# must still have no leading/trailing colon and keep the append fragment.
test_all_managed_cleaned_empty() {
  setup
  local _append="/Users/t/.bun/bin"
  local _dedup="/Users/t/.bun/bin"
  # Compose a PATH where every entry is managed: dedup set covers each segment.
  GUI_ENV_LAUNCHCTL="$LAUNCHCTL_STUB" \
    LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    PATH="$_append:$_append" \
    "$BASH_BIN" "$SCRIPT_UNDER_TEST" "" "$_append" "$_dedup" "true"
  local _agent_exit=$?
  if [ "$_agent_exit" -eq 0 ]; then
    assert_pass "All managed: agent exits 0"
  else
    assert_fail "All managed: agent exits 0" "agent returned non-zero"
  fi
  local _path
  _path="$(last_setenv_path)"
  if [ "$_path" = "$_append" ]; then
    assert_pass "All managed: PATH is exactly the append fragment"
  else
    assert_fail "All managed: PATH is exactly the append fragment" "PATH='$_path'"
  fi
  teardown
}

# ── Run all tests ──────────────────────────────────────────────────────────
test_empty_prepend
test_prepend_fragment
test_dedup_strips_managed
test_all_vars_block
test_all_managed_cleaned_empty

printf '\n%s\n' "---"
printf '%s/%s tests passed\n' "$TESTS_PASSED" "$((TESTS_PASSED + TESTS_FAILED))"
[ "$TESTS_FAILED" -eq 0 ]
