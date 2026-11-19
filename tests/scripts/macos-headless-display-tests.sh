#!/usr/bin/env bash
# Behavioral tests for BetterDisplay headless-screen reconcile logic in
# src/scripts/lib/betterdisplay.sh. A fake BetterDisplay CLI fixture drives
# canned responses and records every invocation so tests assert real
# behavior/call counts, not source text.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

BETTERDISPLAY_LIB="$SCRIPT_DIR/../../src/scripts/lib/betterdisplay.sh"
# shellcheck source=../../src/scripts/lib/betterdisplay.sh
. "$BETTERDISPLAY_LIB"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Write the fake BetterDisplay CLI into $BD_BIN and configure harmless process
# controls. Each test resets scenario state via environment variables/files.
setup_fake_bd() {
  local dir="$TMPDIR_TEST/fake-$BASHPID-$$-$RANDOM"
  mkdir -p "$dir/state"
  BD_BIN="$dir/BetterDisplay"
  BD_APP="$dir/BetterDisplay.app"
  BD_FAKE_LOG="$dir/calls.log"
  BD_FAKE_STATE_DIR="$dir/state"
  # Defaults: app present, running, no-op side effects, fast sleeps.
  : >"$BD_FAKE_LOG"
  rm -f "$BD_FAKE_STATE_DIR/created"
  export BD_BIN BD_APP BD_FAKE_LOG BD_FAKE_STATE_DIR
  export BD_PGREP="$dir/pgrep" BD_OPEN="$dir/open" BD_SLEEP="$dir/sleep"
  export BD_DISPLAY_NAME="HeadlessDisplay"

  cat >"$BD_PGREP" <<'EOF'
#!/usr/bin/env bash
# Reports BetterDisplay running by default; BD_FAKE_PGREP_RUNNING=0 means not running.
if [ "${BD_FAKE_PGREP_RUNNING:-1}" = "0" ]; then
  exit 1
fi
exit 0
EOF
  cat >"$BD_OPEN" <<'EOF'
#!/usr/bin/env bash
printf 'open %s\n' "$*" >>"${BD_FAKE_LOG:?}"
exit 0
EOF
  cat >"$BD_SLEEP" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"${BD_FAKE_LOG:?}"
exit 0
EOF
  cat >"$BD_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${BD_FAKE_LOG:?}"

# State flips after a successful create so verify/re-read can observe the new screen.
created() { [ -f "${BD_FAKE_STATE_DIR:?}/created" ]; }

case "$1" in
  get)
    case "${2:-}" in
      -identifiers)
        if created && [ -n "${BD_FAKE_TAG_IDS_AFTER_CREATE+x}" ]; then
          ids="${BD_FAKE_TAG_IDS_AFTER_CREATE}"
        else
          ids="${BD_FAKE_TAG_IDS-}"
        fi
        for id in $ids; do
          printf '{"tagID":"%s"}\n' "$id"
        done
        exit "${BD_FAKE_IDENTIFIERS_RC:-0}"
        ;;
      -name=*|-tagID=*)
        # connected query: get -name=... -connected or get -tagID=... -connected
        if [ "${3:-}" = "-connected" ] || [ "${2:-}" = "-connected" ] || [[ "${2:-}" == *-connected* ]] || [[ "${3:-}" == *-connected* ]]; then
          :
        fi
        if created && [ -n "${BD_FAKE_CONNECTED_AFTER_CREATE+x}" ]; then
          state="${BD_FAKE_CONNECTED_AFTER_CREATE}"
          rc="${BD_FAKE_CONNECTED_AFTER_CREATE_RC:-0}"
        else
          state="${BD_FAKE_CONNECTED-}"
          rc="${BD_FAKE_CONNECTED_RC:-0}"
        fi
        if [ -n "$state" ]; then
          printf '%s\n' "$state"
        fi
        exit "$rc"
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  create)
    rc="${BD_FAKE_CREATE_RC:-0}"
    if [ "$rc" -eq 0 ]; then
      : >"${BD_FAKE_STATE_DIR:?}/created"
    fi
    exit "$rc"
    ;;
  discard)
    exit "${BD_FAKE_DISCARD_RC:-0}"
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$BD_BIN" "$BD_PGREP" "$BD_OPEN" "$BD_SLEEP"
}

# Count recorded invocations whose logged argument string starts with $1.
count_calls() {
  local prefix="$1" n
  if [ ! -f "$BD_FAKE_LOG" ]; then
    printf '0\n'
    return
  fi
  n="$(grep -c "^${prefix}" "$BD_FAKE_LOG" 2>/dev/null)" || n=0
  printf '%s\n' "${n//$'\n'/}"
}

# Assert that the last (or only) create call contains every expected token.
assert_create_spec() {
  local line
  line="$(grep '^create ' "$BD_FAKE_LOG" | tail -n 1 || true)"
  if [ -z "$line" ]; then
    assert_fail "create spec recorded" "no create call logged"
    return
  fi
  local ok=1 token
  for token in \
    "-type=VirtualScreen" \
    "-virtualScreenName=HeadlessDisplay" \
    "-aspectWidth=16" \
    "-aspectHeight=10" \
    "-multiplierStep=80" \
    "-virtualScreenHiDPI=on" \
    "-connected=on"; do
    case "$line" in
    *"$token"*) ;;
    *)
      assert_fail "create spec contains $token" "got: $line"
      ok=0
      ;;
    esac
  done
  if [ "$ok" -eq 1 ]; then
    assert_pass "create spec includes type/name/aspect/multiplier/HiDPI/connected"
  fi
}

test_bd_connected_predicate() {
  section 1 "bd_connected predicate"

  if bd_connected "on"; then
    assert_pass "bd_connected accepts 'on'"
  else
    assert_fail "bd_connected accepts 'on'" "returned non-zero"
  fi
  if bd_connected "on,on"; then
    assert_pass "bd_connected accepts 'on,on'"
  else
    assert_fail "bd_connected accepts 'on,on'" "returned non-zero"
  fi

  local bad
  for bad in "" "Failed." "off" "off,off" "on,off"; do
    if bd_connected "$bad"; then
      assert_fail "bd_connected rejects '${bad}'" "returned zero (should be unhealthy)"
    else
      assert_pass "bd_connected rejects '${bad}'"
    fi
  done
}

test_reconcile_healthy_single_screen() {
  section 2 "healthy single screen converges"

  setup_fake_bd
  export BD_FAKE_TAG_IDS="11"
  export BD_FAKE_CONNECTED="on,on" BD_FAKE_CONNECTED_RC=0

  local rc=0
  bd_reconcile || rc=$?

  if [ "$rc" -eq 0 ]; then
    assert_pass "healthy single screen: exit 0"
  else
    assert_fail "healthy single screen: exit 0" "rc=$rc status=${BD_RECONCILE_STATUS-}"
  fi
  if [ "${BD_RECONCILE_STATUS-}" = "converged" ]; then
    assert_pass "healthy single screen: status converged"
  else
    assert_fail "healthy single screen: status converged" "got '${BD_RECONCILE_STATUS-}'"
  fi
  if [ "$(count_calls 'create')" -eq 0 ] && [ "$(count_calls 'discard')" -eq 0 ]; then
    assert_pass "healthy single screen: zero create and zero discard calls"
  else
    assert_fail "healthy single screen: zero create/discard" \
      "create=$(count_calls 'create') discard=$(count_calls 'discard')"
  fi
}

test_reconcile_duplicate_tags() {
  section 3 "duplicate tags discard and recreate"

  setup_fake_bd
  export BD_FAKE_TAG_IDS="11 12"
  export BD_FAKE_CONNECTED="on,on" BD_FAKE_CONNECTED_RC=0
  # After create the screen is healthy with a single tag.
  export BD_FAKE_TAG_IDS_AFTER_CREATE="13"
  export BD_FAKE_CONNECTED_AFTER_CREATE="on,on" BD_FAKE_CONNECTED_AFTER_CREATE_RC=0

  local rc=0
  bd_reconcile || rc=$?

  if [ "$rc" -eq 0 ] && [ "${BD_RECONCILE_STATUS-}" = "recreated" ]; then
    assert_pass "duplicate tags: recreated successfully"
  else
    assert_fail "duplicate tags: recreated successfully" \
      "rc=$rc status=${BD_RECONCILE_STATUS-} observed=${BD_RECONCILE_OBSERVED-}"
  fi
  if [ "$(count_calls 'discard')" -eq 2 ]; then
    assert_pass "duplicate tags: both tags discarded"
  else
    assert_fail "duplicate tags: both tags discarded" "discard calls=$(count_calls 'discard') log=$(cat "$BD_FAKE_LOG")"
  fi
  if [ "$(count_calls 'create')" -eq 1 ]; then
    assert_pass "duplicate tags: exactly one create call"
  else
    assert_fail "duplicate tags: exactly one create call" "create calls=$(count_calls 'create')"
  fi
  assert_create_spec
}

test_reconcile_disconnected_missing() {
  section 4 "disconnected/missing creates once"

  setup_fake_bd
  export BD_FAKE_TAG_IDS=""
  export BD_FAKE_CONNECTED="Failed." BD_FAKE_CONNECTED_RC=1
  export BD_FAKE_TAG_IDS_AFTER_CREATE="21"
  export BD_FAKE_CONNECTED_AFTER_CREATE="on,on" BD_FAKE_CONNECTED_AFTER_CREATE_RC=0

  local rc=0
  bd_reconcile || rc=$?

  if [ "$rc" -eq 0 ] && [ "${BD_RECONCILE_STATUS-}" = "recreated" ]; then
    assert_pass "missing screen: creates and verifies (recreated)"
  else
    assert_fail "missing screen: creates and verifies" \
      "rc=$rc status=${BD_RECONCILE_STATUS-} observed=${BD_RECONCILE_OBSERVED-}"
  fi
  if [ "$(count_calls 'create')" -eq 1 ]; then
    assert_pass "missing screen: exactly one create call"
  else
    assert_fail "missing screen: exactly one create call" "create calls=$(count_calls 'create')"
  fi

  # Verify-after-create still unhealthy -> failed.
  setup_fake_bd
  export BD_FAKE_TAG_IDS=""
  export BD_FAKE_CONNECTED="" BD_FAKE_CONNECTED_RC=1
  export BD_FAKE_TAG_IDS_AFTER_CREATE="22"
  export BD_FAKE_CONNECTED_AFTER_CREATE="off,off" BD_FAKE_CONNECTED_AFTER_CREATE_RC=0

  rc=0
  bd_reconcile || rc=$?
  if [ "$rc" -ne 0 ] && [ "${BD_RECONCILE_STATUS-}" = "failed" ]; then
    assert_pass "unhealthy after create: status failed, exit non-zero"
  else
    assert_fail "unhealthy after create: status failed, exit non-zero" \
      "rc=$rc status=${BD_RECONCILE_STATUS-} observed=${BD_RECONCILE_OBSERVED-}"
  fi
  if [ "$(count_calls 'create')" -eq 1 ]; then
    assert_pass "unhealthy after create: still attempted one create"
  else
    assert_fail "unhealthy after create: still attempted one create" "create calls=$(count_calls 'create')"
  fi
}

test_reconcile_get_failure_empty_unhealthy() {
  section 5 "get failure/empty treated as unhealthy"

  setup_fake_bd
  export BD_FAKE_TAG_IDS="31"
  # One tag present but connected state empty/failure -> must discard+create, not success.
  export BD_FAKE_CONNECTED="" BD_FAKE_CONNECTED_RC=1
  export BD_FAKE_TAG_IDS_AFTER_CREATE="32"
  export BD_FAKE_CONNECTED_AFTER_CREATE="on,on" BD_FAKE_CONNECTED_AFTER_CREATE_RC=0

  local rc=0
  bd_reconcile || rc=$?

  if [ "$rc" -eq 0 ] && [ "${BD_RECONCILE_STATUS-}" = "recreated" ]; then
    assert_pass "empty connected with one tag: discard+create (not silent success)"
  else
    assert_fail "empty connected with one tag: discard+create (not silent success)" \
      "rc=$rc status=${BD_RECONCILE_STATUS-}"
  fi
  if [ "$(count_calls 'discard')" -ge 1 ] && [ "$(count_calls 'create')" -eq 1 ]; then
    assert_pass "empty connected with one tag: discarded existing tag and created once"
  else
    assert_fail "empty connected with one tag: discarded existing tag and created once" \
      "discard=$(count_calls 'discard') create=$(count_calls 'create')"
  fi
}

test_create_spec_pinned() {
  section 6 "create spec pinned"

  setup_fake_bd
  export BD_FAKE_TAG_IDS=""
  export BD_FAKE_CONNECTED="Failed." BD_FAKE_CONNECTED_RC=1
  export BD_FAKE_TAG_IDS_AFTER_CREATE="41"
  export BD_FAKE_CONNECTED_AFTER_CREATE="on,on" BD_FAKE_CONNECTED_AFTER_CREATE_RC=0

  bd_reconcile || true
  assert_create_spec
}

# --- Run all tests ---

test_bd_connected_predicate
test_reconcile_healthy_single_screen
test_reconcile_duplicate_tags
test_reconcile_disconnected_missing
test_reconcile_get_failure_empty_unhealthy
test_create_spec_pinned

finish_tests
