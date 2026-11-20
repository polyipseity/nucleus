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
  unset BD_FAKE_PGREP_RUNNING BD_FAKE_OPEN_SETS_RUNNING BD_FAKE_OPEN_RC \
    BD_FAKE_TAG_IDS BD_FAKE_TAG_IDS_AFTER_CREATE BD_FAKE_IDENTIFIERS_RC \
    BD_FAKE_CONNECTED BD_FAKE_CONNECTED_RC \
    BD_FAKE_CONNECTED_AFTER_CREATE BD_FAKE_CONNECTED_AFTER_CREATE_RC \
    BD_FAKE_HIDPI BD_FAKE_HIDPI_RC BD_FAKE_HIDPI_AFTER_CREATE \
    BD_FAKE_ASPECT_W BD_FAKE_ASPECT_W_RC BD_FAKE_ASPECT_W_AFTER_CREATE \
    BD_FAKE_ASPECT_H BD_FAKE_ASPECT_H_RC BD_FAKE_ASPECT_H_AFTER_CREATE \
    BD_FAKE_MULTIPLIER BD_FAKE_MULTIPLIER_RC BD_FAKE_MULTIPLIER_AFTER_CREATE \
    BD_FAKE_RESOLUTION BD_FAKE_RESOLUTION_RC BD_FAKE_RESOLUTION_AFTER_CREATE \
    BD_FAKE_CREATE_RC BD_FAKE_DISCARD_RC
  unset BD_START_TIMEOUT
}

setup_fake_bd() {
  local dir="$TMPDIR_TEST/fake-$BASHPID-$$-$RANDOM"
  mkdir -p "$dir/state"
  BD_BIN="$dir/BetterDisplay"
  BD_FAKE_LOG="$dir/calls.log"
  BD_FAKE_OPEN_LOG="$dir/open.log"
  BD_FAKE_STATE_DIR="$dir/state"
  BD_PGREP="$dir/pgrep"
  BD_OPEN="$dir/open"
  : >"$BD_FAKE_LOG"
  : >"$BD_FAKE_OPEN_LOG"
  rm -f "$BD_FAKE_STATE_DIR/created" "$BD_FAKE_STATE_DIR/pgrep_running"
  export BD_BIN BD_FAKE_LOG BD_FAKE_OPEN_LOG BD_FAKE_STATE_DIR BD_PGREP BD_OPEN
  export BD_DISPLAY_NAME="HeadlessDisplay"
  reset_fake_vars

  cat >"$BD_PGREP" <<'EOF'
#!/usr/bin/env bash
if [ -f "${BD_FAKE_STATE_DIR:?}/pgrep_running" ]; then
  exit 0
fi
if [ "${BD_FAKE_PGREP_RUNNING:-1}" = "0" ]; then
  exit 1
fi
exit 0
EOF

  cat >"$BD_OPEN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BD_FAKE_OPEN_LOG:?}"
if [ "${BD_FAKE_OPEN_SETS_RUNNING:-0}" = "1" ]; then
  : >"${BD_FAKE_STATE_DIR:?}/pgrep_running"
fi
exit "${BD_FAKE_OPEN_RC:-0}"
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

  chmod +x "$BD_PGREP" "$BD_OPEN" "$BD_BIN"
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

count_open_calls() {
  local n
  if [ ! -f "$BD_FAKE_OPEN_LOG" ]; then
    printf '0\n'
    return
  fi
  n="$(wc -l <"$BD_FAKE_OPEN_LOG" 2>/dev/null | tr -d ' ')" || n=0
  printf '%s\n' "${n:-0}"
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

test_bd_defaults_start_verify() {
  section 4 "bd defaults, start, and verify"

  (
    unset BD_PGREP BD_APP BD_OPEN BD_START_TIMEOUT
    # shellcheck source=../../src/scripts/lib/betterdisplay.sh
    . "$BETTERDISPLAY_LIB"
    if [ "${BD_PGREP-}" = "/usr/bin/pgrep" ]; then
      assert_pass "BD_PGREP defaults to /usr/bin/pgrep"
    else
      assert_fail "BD_PGREP defaults to /usr/bin/pgrep" "got=${BD_PGREP-}"
    fi
  )

  setup_fake_bd
  BD_FAKE_PGREP_RUNNING=0
  BD_FAKE_OPEN_SETS_RUNNING=1
  BD_START_TIMEOUT=3
  export BD_FAKE_PGREP_RUNNING BD_FAKE_OPEN_SETS_RUNNING BD_START_TIMEOUT
  local rc=0
  bd_start_app || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(count_open_calls)" -eq 1 ]; then
    assert_pass "bd_start_app success: returns 0 and calls open once"
  else
    assert_fail "bd_start_app success: returns 0 and calls open once" \
      "rc=$rc open_calls=$(count_open_calls)"
  fi
  local open_line
  open_line="$(cat "$BD_FAKE_OPEN_LOG")"
  case "$open_line" in
  *"-g -a "*) assert_pass "bd_start_app uses open -g -a" ;;
  *) assert_fail "bd_start_app uses open -g -a" "got=$open_line" ;;
  esac
  case "$open_line" in
  *" -b "*) assert_fail "bd_start_app does not use -b" "got=$open_line" ;;
  *) assert_pass "bd_start_app does not use -b" ;;
  esac

  setup_fake_bd
  BD_FAKE_PGREP_RUNNING=0
  BD_FAKE_OPEN_SETS_RUNNING=0
  BD_START_TIMEOUT=2
  export BD_FAKE_PGREP_RUNNING BD_FAKE_OPEN_SETS_RUNNING BD_START_TIMEOUT
  rc=0
  bd_start_app || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "bd_start_app timeout: returns 1"
  else
    assert_fail "bd_start_app timeout: returns 1" "rc=$rc"
  fi

  setup_fake_bd
  rc=0
  bd_verify || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_pass "bd_verify true for healthy single matching screen"
  else
    assert_fail "bd_verify true for healthy single matching screen" "rc=$rc"
  fi

  setup_fake_bd
  export BD_FAKE_HIDPI="off"
  rc=0
  bd_verify || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "bd_verify false when spec mismatches"
  else
    assert_fail "bd_verify false when spec mismatches" "rc=$rc"
  fi

  setup_fake_bd
  export BD_FAKE_TAG_IDS="11 12"
  rc=0
  bd_verify || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "bd_verify false when tag count is 2"
  else
    assert_fail "bd_verify false when tag count is 2" "rc=$rc"
  fi
}

test_apply_script() {
  section 5 "apply script"

  setup_fake_bd
  export BD_FAKE_TAG_IDS="11"
  export BD_FAKE_CONNECTED="on,on" BD_FAKE_CONNECTED_RC=0
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
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
  export BD_FAKE_TAG_IDS_AFTER_CREATE="11"
  export BD_FAKE_CONNECTED_AFTER_CREATE="on,on" BD_FAKE_CONNECTED_AFTER_CREATE_RC=0
  export BD_FAKE_HIDPI_AFTER_CREATE="on"
  export BD_FAKE_ASPECT_W_AFTER_CREATE="16" BD_FAKE_ASPECT_H_AFTER_CREATE="10"
  export BD_FAKE_MULTIPLIER_AFTER_CREATE="80" BD_FAKE_RESOLUTION_AFTER_CREATE="1280x800"
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_FAKE_TAG_IDS="$BD_FAKE_TAG_IDS" BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" \
    BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" BD_FAKE_HIDPI="$BD_FAKE_HIDPI" \
    BD_FAKE_TAG_IDS_AFTER_CREATE="$BD_FAKE_TAG_IDS_AFTER_CREATE" \
    BD_FAKE_CONNECTED_AFTER_CREATE="$BD_FAKE_CONNECTED_AFTER_CREATE" \
    BD_FAKE_CONNECTED_AFTER_CREATE_RC="$BD_FAKE_CONNECTED_AFTER_CREATE_RC" \
    BD_FAKE_HIDPI_AFTER_CREATE="$BD_FAKE_HIDPI_AFTER_CREATE" \
    BD_FAKE_ASPECT_W_AFTER_CREATE="$BD_FAKE_ASPECT_W_AFTER_CREATE" \
    BD_FAKE_ASPECT_H_AFTER_CREATE="$BD_FAKE_ASPECT_H_AFTER_CREATE" \
    BD_FAKE_MULTIPLIER_AFTER_CREATE="$BD_FAKE_MULTIPLIER_AFTER_CREATE" \
    BD_FAKE_RESOLUTION_AFTER_CREATE="$BD_FAKE_RESOLUTION_AFTER_CREATE" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -eq 0 ] && [ "$(count_create_calls)" -eq 1 ]; then
    assert_pass "apply spec drift (HiDPI off): converge once"
  else
    assert_fail "apply spec drift (HiDPI off): converge once" \
      "rc=$RUN_RC creates=$(count_create_calls) err=$RUN_ERR"
  fi

  setup_fake_bd
  BD_FAKE_PGREP_RUNNING=0
  BD_FAKE_OPEN_SETS_RUNNING=1
  export BD_FAKE_PGREP_RUNNING BD_FAKE_OPEN_SETS_RUNNING
  export BD_FAKE_CONNECTED="Failed." BD_FAKE_CONNECTED_RC=1
  export BD_FAKE_TAG_IDS_AFTER_CREATE="11"
  export BD_FAKE_CONNECTED_AFTER_CREATE="on,on" BD_FAKE_CONNECTED_AFTER_CREATE_RC=0
  export BD_FAKE_HIDPI_AFTER_CREATE="on"
  export BD_FAKE_ASPECT_W_AFTER_CREATE="16" BD_FAKE_ASPECT_H_AFTER_CREATE="10"
  export BD_FAKE_MULTIPLIER_AFTER_CREATE="80" BD_FAKE_RESOLUTION_AFTER_CREATE="1280x800"
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_FAKE_PGREP_RUNNING="$BD_FAKE_PGREP_RUNNING" BD_FAKE_OPEN_SETS_RUNNING="$BD_FAKE_OPEN_SETS_RUNNING" \
    BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" \
    BD_FAKE_TAG_IDS_AFTER_CREATE="$BD_FAKE_TAG_IDS_AFTER_CREATE" \
    BD_FAKE_CONNECTED_AFTER_CREATE="$BD_FAKE_CONNECTED_AFTER_CREATE" \
    BD_FAKE_CONNECTED_AFTER_CREATE_RC="$BD_FAKE_CONNECTED_AFTER_CREATE_RC" \
    BD_FAKE_HIDPI_AFTER_CREATE="$BD_FAKE_HIDPI_AFTER_CREATE" \
    BD_FAKE_ASPECT_W_AFTER_CREATE="$BD_FAKE_ASPECT_W_AFTER_CREATE" \
    BD_FAKE_ASPECT_H_AFTER_CREATE="$BD_FAKE_ASPECT_H_AFTER_CREATE" \
    BD_FAKE_MULTIPLIER_AFTER_CREATE="$BD_FAKE_MULTIPLIER_AFTER_CREATE" \
    BD_FAKE_RESOLUTION_AFTER_CREATE="$BD_FAKE_RESOLUTION_AFTER_CREATE" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -eq 0 ] && [ "$(count_create_calls)" -eq 1 ] && [ "$(count_open_calls)" -eq 1 ]; then
    assert_pass "apply app absent and started: starts, converges, verifies"
  else
    assert_fail "apply app absent and started: starts, converges, verifies" \
      "rc=$RUN_RC creates=$(count_create_calls) open_calls=$(count_open_calls) err=$RUN_ERR"
  fi

  setup_fake_bd
  BD_FAKE_PGREP_RUNNING=0
  BD_FAKE_OPEN_SETS_RUNNING=0
  BD_START_TIMEOUT=2
  export BD_FAKE_PGREP_RUNNING BD_FAKE_OPEN_SETS_RUNNING BD_START_TIMEOUT
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_FAKE_PGREP_RUNNING="$BD_FAKE_PGREP_RUNNING" BD_FAKE_OPEN_SETS_RUNNING="$BD_FAKE_OPEN_SETS_RUNNING" \
    BD_START_TIMEOUT="$BD_START_TIMEOUT" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -ne 0 ] && [ "$(count_discard_calls)" -eq 0 ] && [ "$(count_create_calls)" -eq 0 ]; then
    assert_pass "apply app absent and start times out: dies, zero converge/create"
  else
    assert_fail "apply app absent and start times out: dies, zero converge/create" \
      "rc=$RUN_RC discards=$(count_discard_calls) creates=$(count_create_calls) err=$RUN_ERR"
  fi
  case "$RUN_ERR" in
  *"failed to start BetterDisplay; cannot configure headless display"*) assert_pass "apply start timeout: reports start-failure message" ;;
  *) assert_fail "apply start timeout: reports start-failure message" "stderr=$RUN_ERR" ;;
  esac

  setup_fake_bd
  BD_FAKE_PGREP_RUNNING=0
  BD_FAKE_OPEN_SETS_RUNNING=0
  BD_FAKE_OPEN_RC=1
  BD_START_TIMEOUT=1
  export BD_FAKE_PGREP_RUNNING BD_FAKE_OPEN_SETS_RUNNING BD_FAKE_OPEN_RC BD_START_TIMEOUT
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_FAKE_PGREP_RUNNING="$BD_FAKE_PGREP_RUNNING" BD_FAKE_OPEN_SETS_RUNNING="$BD_FAKE_OPEN_SETS_RUNNING" \
    BD_FAKE_OPEN_RC="$BD_FAKE_OPEN_RC" BD_START_TIMEOUT="$BD_START_TIMEOUT" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -ne 0 ] && [ "$(count_discard_calls)" -eq 0 ] && [ "$(count_create_calls)" -eq 0 ]; then
    assert_pass "apply app absent and open fails: dies, zero converge/create"
  else
    assert_fail "apply app absent and open fails: dies, zero converge/create" \
      "rc=$RUN_RC discards=$(count_discard_calls) creates=$(count_create_calls) err=$RUN_ERR"
  fi
  case "$RUN_ERR" in
  *"failed to start BetterDisplay; cannot configure headless display"*) assert_pass "apply open failure: reports start-failure message" ;;
  *) assert_fail "apply open failure: reports start-failure message" "stderr=$RUN_ERR" ;;
  esac

  setup_fake_bd
  export BD_FAKE_CONNECTED="Failed." BD_FAKE_CONNECTED_RC=1
  export BD_FAKE_HIDPI_AFTER_CREATE="off"
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
    BD_FAKE_CONNECTED="$BD_FAKE_CONNECTED" BD_FAKE_CONNECTED_RC="$BD_FAKE_CONNECTED_RC" \
    BD_FAKE_HIDPI_AFTER_CREATE="$BD_FAKE_HIDPI_AFTER_CREATE" \
    bash "$APPLY_SCRIPT"
  if [ "$RUN_RC" -ne 0 ] && [ "$(count_create_calls)" -eq 1 ]; then
    assert_pass "apply converge then verify fails: dies after converge"
  else
    assert_fail "apply converge then verify fails: dies after converge" \
      "rc=$RUN_RC creates=$(count_create_calls) err=$RUN_ERR"
  fi
  case "$RUN_ERR" in
  *"did not verify after converge"*) assert_pass "apply verify failure: reports verify-failure message" ;;
  *) assert_fail "apply verify failure: reports verify-failure message" "stderr=$RUN_ERR" ;;
  esac
}

test_heartbeat_script() {
  section 6 "heartbeat script"

  setup_fake_bd
  export BD_FAKE_PGREP_RUNNING=0
  run_script_capture env \
    HOME="$HOME" NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" NUCLEUS_REPO_ROOT="$NUCLEUS_REPO_ROOT" \
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

test_activation_path_regression() {
  section 7 "activation-like PATH regression"

  local fakebin="$TMPDIR_TEST/fakebin-path"
  mkdir -p "$fakebin"
  ln -sf /bin/bash "$fakebin/bash"
  ln -sf /usr/bin/env "$fakebin/env"
  ln -sf /usr/bin/awk "$fakebin/awk"
  ln -sf /usr/bin/sort "$fakebin/sort"
  ln -sf /bin/sleep "$fakebin/sleep"

  (
    PATH="$fakebin"
    unset BD_PGREP
    # shellcheck source=../../src/scripts/lib/betterdisplay.sh
    . "$BETTERDISPLAY_LIB"
    if [ "${BD_PGREP-}" = "/usr/bin/pgrep" ]; then
      assert_pass "activation-like PATH: BD_PGREP remains absolute default"
    else
      assert_fail "activation-like PATH: BD_PGREP remains absolute default" "got=${BD_PGREP-}"
    fi
    BD_PGREP="/usr/bin/true"
    if bd_app_running; then
      assert_pass "activation-like PATH: bd_app_running uses BD_PGREP path"
    else
      assert_fail "activation-like PATH: bd_app_running uses BD_PGREP path" "rc=$?"
    fi
  )
}

test_bd_probe
test_bd_spec_matches
test_bd_converge
test_bd_defaults_start_verify
test_apply_script
test_heartbeat_script
test_activation_path_regression

finish_tests
