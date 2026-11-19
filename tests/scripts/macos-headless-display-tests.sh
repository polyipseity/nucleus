#!/usr/bin/env bash
# Behavioral tests for BetterDisplay headless-screen helpers, heartbeat, and
# apply script. A fake BetterDisplay CLI drives canned responses and records
# every invocation.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

init_test_state
ensure_safe_rm_env

BETTERDISPLAY_LIB="$SCRIPT_DIR/../../src/scripts/lib/betterdisplay.sh"
HEARTBEAT_SCRIPT="$SCRIPT_DIR/../../src/platforms/macOS/scripts/macos-heartbeat-betterdisplay.sh"
APPLY_SCRIPT="$SCRIPT_DIR/../../src/platforms/macOS/scripts/macos-configure-headless-display.sh"

# shellcheck source=../../src/scripts/lib/betterdisplay.sh
. "$BETTERDISPLAY_LIB"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

reset_fake_vars() {
  unset BD_FAKE_PGREP_RUNNING \
    BD_FAKE_TAG_IDS BD_FAKE_TAG_IDS_AFTER_CREATE BD_FAKE_IDENTIFIERS_RC \
    BD_FAKE_CONNECTED BD_FAKE_CONNECTED_RC \
    BD_FAKE_CONNECTED_AFTER_CREATE BD_FAKE_CONNECTED_AFTER_CREATE_RC \
    BD_FAKE_HIDPI BD_FAKE_HIDPI_RC BD_FAKE_HIDPI_AFTER_CREATE \
    BD_FAKE_ASPECT_W BD_FAKE_ASPECT_W_RC BD_FAKE_ASPECT_W_AFTER_CREATE \
    BD_FAKE_ASPECT_H BD_FAKE_ASPECT_H_RC BD_FAKE_ASPECT_H_AFTER_CREATE \
    BD_FAKE_MULTIPLIER BD_FAKE_MULTIPLIER_RC BD_FAKE_MULTIPLIER_AFTER_CREATE \
    BD_FAKE_RESOLUTION BD_FAKE_RESOLUTION_RC BD_FAKE_RESOLUTION_AFTER_CREATE \
    BD_FAKE_CREATE_RC BD_FAKE_DISCARD_RC
}

setup_fake_bd() {
  local dir="$TMPDIR_TEST/fake-$BASHPID-$$-$RANDOM"
  mkdir -p "$dir/state"
  BD_BIN="$dir/BetterDisplay"
  BD_FAKE_LOG="$dir/calls.log"
  BD_FAKE_STATE_DIR="$dir/state"
  BD_PGREP="$dir/pgrep"
  : >"$BD_FAKE_LOG"
  rm -f "$BD_FAKE_STATE_DIR/created"
  export BD_BIN BD_FAKE_LOG BD_FAKE_STATE_DIR BD_PGREP
  export BD_DISPLAY_NAME="HeadlessDisplay"
  reset_fake_vars

  cat >"$BD_PGREP" <<'EOF'
#!/usr/bin/env bash
if [ "${BD_FAKE_PGREP_RUNNING:-1}" = "0" ]; then
  exit 1
fi
exit 0
EOF

  cat >"$BD_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${BD_FAKE_LOG:?}"

created() { [ -f "${BD_FAKE_STATE_DIR:?}/created" ]; }

case "${1:-}" in
  get)
    for arg in "$@"; do
      case "$arg" in
        -identifiers)
          if created && [ -n "${BD_FAKE_TAG_IDS_AFTER_CREATE+x}" ]; then
            ids="${BD_FAKE_TAG_IDS_AFTER_CREATE}"
          elif [ -n "${BD_FAKE_TAG_IDS+x}" ]; then
            ids="${BD_FAKE_TAG_IDS}"
          else
            ids="11"
          fi
          rc="${BD_FAKE_IDENTIFIERS_RC:-0}"
          for id in $ids; do
            [ -n "$id" ] || continue
            printf '{"tagID":"%s"}\n' "$id"
          done
          exit "$rc"
          ;;
      esac
    done

    for arg in "$@"; do
      case "$arg" in
        -connected)
          if created && [ -n "${BD_FAKE_CONNECTED_AFTER_CREATE+x}" ]; then
            state="${BD_FAKE_CONNECTED_AFTER_CREATE}"
            rc="${BD_FAKE_CONNECTED_AFTER_CREATE_RC:-0}"
          elif [ -n "${BD_FAKE_CONNECTED+x}" ]; then
            state="${BD_FAKE_CONNECTED}"
            rc="${BD_FAKE_CONNECTED_RC:-0}"
          else
            state="on,on"
            rc=0
          fi
          if [ -n "$state" ]; then
            printf '%s\n' "$state"
          fi
          exit "$rc"
          ;;
      esac
    done

    for arg in "$@"; do
      case "$arg" in
        -virtualScreenHiDPI)
          if created && [ -n "${BD_FAKE_HIDPI_AFTER_CREATE+x}" ]; then
            v="${BD_FAKE_HIDPI_AFTER_CREATE}"
          elif [ -n "${BD_FAKE_HIDPI+x}" ]; then
            v="${BD_FAKE_HIDPI}"
          else
            v="on"
          fi
          rc="${BD_FAKE_HIDPI_RC:-0}"
          [ -n "$v" ] && printf '%s\n' "$v"
          exit "$rc"
          ;;
        -aspectWidth)
          if created && [ -n "${BD_FAKE_ASPECT_W_AFTER_CREATE+x}" ]; then
            v="${BD_FAKE_ASPECT_W_AFTER_CREATE}"
          elif [ -n "${BD_FAKE_ASPECT_W+x}" ]; then
            v="${BD_FAKE_ASPECT_W}"
          else
            v="16"
          fi
          rc="${BD_FAKE_ASPECT_W_RC:-0}"
          [ -n "$v" ] && printf '%s\n' "$v"
          exit "$rc"
          ;;
        -aspectHeight)
          if created && [ -n "${BD_FAKE_ASPECT_H_AFTER_CREATE+x}" ]; then
            v="${BD_FAKE_ASPECT_H_AFTER_CREATE}"
          elif [ -n "${BD_FAKE_ASPECT_H+x}" ]; then
            v="${BD_FAKE_ASPECT_H}"
          else
            v="10"
          fi
          rc="${BD_FAKE_ASPECT_H_RC:-0}"
          [ -n "$v" ] && printf '%s\n' "$v"
          exit "$rc"
          ;;
        -multiplierStep)
          if created && [ -n "${BD_FAKE_MULTIPLIER_AFTER_CREATE+x}" ]; then
            v="${BD_FAKE_MULTIPLIER_AFTER_CREATE}"
          elif [ -n "${BD_FAKE_MULTIPLIER+x}" ]; then
            v="${BD_FAKE_MULTIPLIER}"
          else
            v="80"
          fi
          rc="${BD_FAKE_MULTIPLIER_RC:-0}"
          [ -n "$v" ] && printf '%s\n' "$v"
          exit "$rc"
          ;;
        -resolution)
          if created && [ -n "${BD_FAKE_RESOLUTION_AFTER_CREATE+x}" ]; then
            v="${BD_FAKE_RESOLUTION_AFTER_CREATE}"
          elif [ -n "${BD_FAKE_RESOLUTION+x}" ]; then
            v="${BD_FAKE_RESOLUTION}"
          else
            v="1280x800"
          fi
          rc="${BD_FAKE_RESOLUTION_RC:-0}"
          [ -n "$v" ] && printf '%s\n' "$v"
          exit "$rc"
          ;;
      esac
    done
    exit 0
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

  chmod +x "$BD_PGREP" "$BD_BIN"
}

count_calls() {
  local prefix="$1" n
  if [ ! -f "$BD_FAKE_LOG" ]; then
    printf '0\n'
    return
  fi
  n="$(grep -c "^${prefix}" "$BD_FAKE_LOG" 2>/dev/null)" || n=0
  printf '%s\n' "${n//$'\n'/}"
}

count_connected_calls() {
  local n
  if [ ! -f "$BD_FAKE_LOG" ]; then
    printf '0\n'
    return
  fi
  n="$(grep -c ' -connected$' "$BD_FAKE_LOG" 2>/dev/null)" || n=0
  printf '%s\n' "${n//$'\n'/}"
}

count_create_calls() { count_calls 'create '; }
count_discard_calls() { count_calls 'discard '; }

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

run_script_capture() {
  # Runs command, captures stderr and exit into RUN_ERR/RUN_RC.
  local err
  err="$TMPDIR_TEST/run.err.$$.$RANDOM"
  set +e
  "$@" >/dev/null 2>"$err"
  RUN_RC=$?
  set -e
  RUN_ERR="$(cat "$err")"
  rm -f "$err"
}

test_bd_probe() {
  section 1 "bd_probe"

  setup_fake_bd
  export BD_FAKE_CONNECTED="on,on" BD_FAKE_CONNECTED_RC=0
  bd_probe
  if [ "${BD_PROBE_STATE-}" = "healthy" ] && [ "${BD_PROBE_OBSERVED-}" = "on,on" ]; then
    assert_pass "bd_probe healthy: state healthy, observed on,on"
  else
    assert_fail "bd_probe healthy: state healthy, observed on,on" \
      "state=${BD_PROBE_STATE-} observed=${BD_PROBE_OBSERVED-}"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="on,on,on,on" BD_FAKE_CONNECTED_RC=0
  bd_probe
  if [ "${BD_PROBE_STATE-}" = "anomaly" ]; then
    assert_pass "bd_probe anomaly: on,on,on,on"
  else
    assert_fail "bd_probe anomaly: on,on,on,on" "state=${BD_PROBE_STATE-} observed=${BD_PROBE_OBSERVED-}"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="off,on" BD_FAKE_CONNECTED_RC=0
  bd_probe
  if [ "${BD_PROBE_STATE-}" = "anomaly" ]; then
    assert_pass "bd_probe anomaly: off,on"
  else
    assert_fail "bd_probe anomaly: off,on" "state=${BD_PROBE_STATE-} observed=${BD_PROBE_OBSERVED-}"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="Failed." BD_FAKE_CONNECTED_RC=1
  bd_probe
  if [ "${BD_PROBE_STATE-}" = "missing" ]; then
    assert_pass "bd_probe missing: Failed. rc 1"
  else
    assert_fail "bd_probe missing: Failed. rc 1" "state=${BD_PROBE_STATE-} observed=${BD_PROBE_OBSERVED-}"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="" BD_FAKE_CONNECTED_RC=1
  bd_probe
  if [ "${BD_PROBE_STATE-}" = "missing" ]; then
    assert_pass "bd_probe missing: empty rc 1"
  else
    assert_fail "bd_probe missing: empty rc 1" "state=${BD_PROBE_STATE-} observed=${BD_PROBE_OBSERVED-}"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="" BD_FAKE_CONNECTED_RC=0
  bd_probe
  if [ "${BD_PROBE_STATE-}" = "missing" ]; then
    assert_pass "bd_probe missing: empty rc 0"
  else
    assert_fail "bd_probe missing: empty rc 0" "state=${BD_PROBE_STATE-} observed=${BD_PROBE_OBSERVED-}"
  fi
}

test_bd_spec_matches() {
  section 2 "bd_spec_matches"

  setup_fake_bd
  local rc=0
  bd_spec_matches || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_pass "bd_spec_matches true for default spec"
  else
    assert_fail "bd_spec_matches true for default spec" "rc=$rc"
  fi

  setup_fake_bd
  export BD_FAKE_HIDPI="off"
  rc=0
  bd_spec_matches || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "bd_spec_matches false when HiDPI off"
  else
    assert_fail "bd_spec_matches false when HiDPI off" "rc=$rc"
  fi

  setup_fake_bd
  export BD_FAKE_RESOLUTION=""
  rc=0
  bd_spec_matches || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "bd_spec_matches false when resolution empty"
  else
    assert_fail "bd_spec_matches false when resolution empty" "rc=$rc"
  fi
}

test_bd_converge() {
  section 3 "bd_converge"

  setup_fake_bd
  export BD_FAKE_TAG_IDS="11 12"
  local rc=0
  bd_converge || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_pass "bd_converge discards existing tags and creates once"
  else
    assert_fail "bd_converge discards existing tags and creates once" "rc=$rc"
  fi
  if [ "$(count_discard_calls)" -eq 2 ] && [ "$(count_create_calls)" -eq 1 ]; then
    assert_pass "bd_converge call counts: 2 discards, 1 create"
  else
    assert_fail "bd_converge call counts: 2 discards, 1 create" \
      "discards=$(count_discard_calls) creates=$(count_create_calls)"
  fi
  assert_create_spec

  setup_fake_bd
  export BD_FAKE_CREATE_RC=1
  rc=0
  bd_converge || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "bd_converge fails if create fails"
  else
    assert_fail "bd_converge fails if create fails" "rc=$rc"
  fi

  setup_fake_bd
  export BD_FAKE_TAG_IDS="21"
  export BD_FAKE_DISCARD_RC=1
  rc=0
  bd_converge || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "bd_converge fails if discard fails"
  else
    assert_fail "bd_converge fails if discard fails" "rc=$rc"
  fi
  if [ "$(count_create_calls)" -eq 0 ]; then
    assert_pass "bd_converge does not create after discard failure"
  else
    assert_fail "bd_converge does not create after discard failure" "creates=$(count_create_calls)"
  fi
}

test_apply_script() {
  section 4 "apply script"

  setup_fake_bd
  export BD_FAKE_TAG_IDS="11"
  export BD_FAKE_CONNECTED="on,on" BD_FAKE_CONNECTED_RC=0
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_TAG_IDS="$BD_FAKE_TAG_IDS" BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" \
    BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -eq 0 ] && [ "$(count_discard_calls)" -eq 0 ] && [ "$(count_create_calls)" -eq 0 ]; then
    assert_pass "apply healthy: zero discard/create"
  else
    assert_fail "apply healthy: zero discard/create" \
      "rc=$RUN_RC discards=$(count_discard_calls) creates=$(count_create_calls) err=$RUN_ERR"
  fi

  setup_fake_bd
  export BD_FAKE_TAG_IDS="11"
  export BD_FAKE_CONNECTED="on,on" BD_FAKE_CONNECTED_RC=0
  export BD_FAKE_HIDPI="off"
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_TAG_IDS="$BD_FAKE_TAG_IDS" BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" \
    BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" BD_FAKE_HIDPI="$BD_FAKE_HIDPI" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -eq 0 ] && [ "$(count_create_calls)" -eq 1 ]; then
    assert_pass "apply spec drift (HiDPI off): converge once"
  else
    assert_fail "apply spec drift (HiDPI off): converge once" \
      "rc=$RUN_RC creates=$(count_create_calls) err=$RUN_ERR"
  fi

  setup_fake_bd
  export BD_FAKE_PGREP_RUNNING=0
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_PGREP_RUNNING="$BD_FAKE_PGREP_RUNNING" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -ne 0 ] && [ "$(count_connected_calls)" -eq 0 ] && [ "$(count_discard_calls)" -eq 0 ] && [ "$(count_create_calls)" -eq 0 ]; then
    assert_pass "apply app not running: dies, zero CLI calls"
  else
    assert_fail "apply app not running: dies, zero CLI calls" \
      "rc=$RUN_RC connected=$(count_connected_calls) discards=$(count_discard_calls) creates=$(count_create_calls) err=$RUN_ERR"
  fi
  case "$RUN_ERR" in
  *"BetterDisplay is not running"*) assert_pass "apply app not running: reports expected error" ;;
  *) assert_fail "apply app not running: reports expected error" "stderr=$RUN_ERR" ;;
  esac
}

test_heartbeat_script() {
  section 5 "heartbeat script"

  setup_fake_bd
  export BD_FAKE_PGREP_RUNNING=0
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_PGREP_RUNNING="$BD_FAKE_PGREP_RUNNING" \
    BD_INTERVAL=0 BD_HEARTBEAT_ONCE=1 \
    bash "$HEARTBEAT_SCRIPT"
  if [ "$RUN_RC" -ne 0 ] && [ "$(count_connected_calls)" -eq 0 ] && [ "$(count_discard_calls)" -eq 0 ] && [ "$(count_create_calls)" -eq 0 ]; then
    assert_pass "heartbeat app not running: exit 1, zero CLI calls"
  else
    assert_fail "heartbeat app not running: exit 1, zero CLI calls" \
      "rc=$RUN_RC connected=$(count_connected_calls) discards=$(count_discard_calls) creates=$(count_create_calls)"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="on,on" BD_FAKE_CONNECTED_RC=0
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" \
    BD_INTERVAL=0 BD_HEARTBEAT_ONCE=1 \
    bash "$HEARTBEAT_SCRIPT"
  if [ "$RUN_RC" -eq 0 ] && [ "$(count_discard_calls)" -eq 0 ] && [ "$(count_create_calls)" -eq 0 ] && [ "$(count_connected_calls)" -eq 1 ]; then
    assert_pass "heartbeat healthy: exit 0, zero mutations, one connected call"
  else
    assert_fail "heartbeat healthy: exit 0, zero mutations, one connected call" \
      "rc=$RUN_RC connected=$(count_connected_calls) discards=$(count_discard_calls) creates=$(count_create_calls) err=$RUN_ERR"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="on,on,on,on" BD_FAKE_CONNECTED_RC=0
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" \
    BD_INTERVAL=0 BD_HEARTBEAT_ONCE=1 \
    bash "$HEARTBEAT_SCRIPT"
  if [ "$RUN_RC" -eq 0 ] && [ "$(count_discard_calls)" -eq 0 ] && [ "$(count_create_calls)" -eq 0 ]; then
    assert_pass "heartbeat anomaly: exit 0, zero mutations"
  else
    assert_fail "heartbeat anomaly: exit 0, zero mutations" \
      "rc=$RUN_RC discards=$(count_discard_calls) creates=$(count_create_calls) err=$RUN_ERR"
  fi
  case "$RUN_ERR" in
  *"headless display probe returned unexpected state: on,on,on,on"*) assert_pass "heartbeat anomaly: notice printed" ;;
  *) assert_fail "heartbeat anomaly: notice printed" "stderr=$RUN_ERR" ;;
  esac

  setup_fake_bd
  export BD_FAKE_CONNECTED="Failed." BD_FAKE_CONNECTED_RC=1
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" \
    BD_INTERVAL=0 BD_HEARTBEAT_ONCE=1 \
    bash "$HEARTBEAT_SCRIPT"
  if [ "$RUN_RC" -eq 0 ] && [ "$(count_create_calls)" -eq 1 ]; then
    assert_pass "heartbeat missing + create success: exit 0"
  else
    assert_fail "heartbeat missing + create success: exit 0" \
      "rc=$RUN_RC creates=$(count_create_calls) err=$RUN_ERR"
  fi

  setup_fake_bd
  export BD_FAKE_CONNECTED="Failed." BD_FAKE_CONNECTED_RC=1
  export BD_FAKE_CREATE_RC=1
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_BIN="$BD_BIN" BD_PGREP="$BD_PGREP" BD_DISPLAY_NAME="$BD_DISPLAY_NAME" \
    BD_FAKE_LOG="$BD_FAKE_LOG" BD_FAKE_STATE_DIR="$BD_FAKE_STATE_DIR" \
    BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" \
    BD_FAKE_CREATE_RC="$BD_FAKE_CREATE_RC" \
    BD_INTERVAL=0 BD_HEARTBEAT_ONCE=1 \
    bash "$HEARTBEAT_SCRIPT"
  if [ "$RUN_RC" -ne 0 ]; then
    assert_pass "heartbeat missing + create fail: exit 1"
  else
    assert_fail "heartbeat missing + create fail: exit 1" "rc=$RUN_RC err=$RUN_ERR"
  fi
}

test_bd_probe
test_bd_spec_matches
test_bd_converge
test_apply_script
test_heartbeat_script

finish_tests
