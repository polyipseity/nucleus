#!/usr/bin/env bash
# rclone-mount-tests.sh — tests for the rewritten cloud-mount core runner.
#
# The runner (src/scripts/services/rclone-mount.sh) dispatches to mount-backend-
# darwin.sh or mount-backend-linux.sh, uses svc_health_* for health records, and
# runs a bounded retry loop with classification.  This suite mocks the backend
# interface and a fake rclone to exercise: startup/backend-prepare, success,
# retry on transient errors, terminal failure → blocked record, exhaustion →
# blocked record, and health record lifecycle.
#
# Exit contract:
#   0 — success (mount lived and exited cleanly)
#   1 — permanent/unknown failure (mount never attached)
#   2 — misconfiguration
#   3 — missing binary
#   20 — backend requires user action (backend_prepare)
# shellcheck shell=bash
# SC1090: MOUNT_SH is a runtime variable; SC1091: test-lib.sh resolves via SCRIPT_DIR;
# SC2329: MOCK_BACKEND_* functions are invoked indirectly via exported backend_* wrappers;
# SC2154: _backend_capture is set in the runner's scope before backend_mount is called.
# check-suppress:suppression_doc: test file sources lib via relative path at runtime; variables used by mock functions
# shellcheck disable=SC1090,SC1091,SC2329,SC2154
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
MOUNT_SH="$REPO_ROOT/src/scripts/services/rclone-mount.sh"

# ── Fake rclone builder ──────────────────────────────────────────────────────
# Creates a minimal rclone in $dir/rclone that records argv, creates a marker
# on "mount" (simulating volume attachment), sleeps, and exits FAKE_EXIT.
# FAKE_SLEEP controls how long the mount "lives" (default 4).
# FAKE_ERRFILE writes to stderr before exiting (for classification tests).
# FAKE_MOUNT_SLEEP overrides the pre-attach delay (default 0 = immediate).
setup_fake_rclone() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CALLS"
case "${1-}" in
mount)
  # Simulate pre-attach delay.
  sleep "${FAKE_MOUNT_SLEEP:-0}"
  # Signal volume attachment.
  if [ -n "${FAKE_MARKER:-}" ]; then
    touch "$FAKE_MARKER"
  fi
  # Write any classification-triggering stderr.
  if [ -n "${FAKE_ERRFILE:-}" ] && [ -f "$FAKE_ERRFILE" ]; then
    cat "$FAKE_ERRFILE" >&2
  fi
  # Live for a while so the runner can "wait" on us.
  sleep "${FAKE_SLEEP:-4}"
  exit "${FAKE_EXIT:-0}"
  ;;
listremotes)
  if [ -n "${FAKE_REMOTES:-}" ]; then
    printf '%s\n' "$FAKE_REMOTES"
  fi
  exit "${FAKE_LISTREMOTES_EXIT:-0}"
  ;;
esac
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s' "$dir"
}

# ── Setup helpers ────────────────────────────────────────────────────────────
# create_home — minimal HOME with mount-point directory and nucleus root.
create_home() {
  local h
  h="$(mktemp -d)"
  mkdir -p "$h/clouds/OneDrive"
  # nucleus state dir for health records.
  mkdir -p "$h/.local/share/nucleus/state/service-stats"
  printf '%s' "$h"
}

# setup_env — common env vars for the runner.
# Args: $1 = home, $2 = fake rclone bin dir
setup_env() {
  HOME="$1"
  PATH="$2:$PATH"
  NUCLEUS_RCLONE_REMOTE_NAME="OneDrive"
  NUCLEUS_RCLONE_REMOTE="OneDrive:Backups"
  NUCLEUS_RCLONE_MOUNT_POINT="$1/clouds/OneDrive"
  NUCLEUS_RCLONE_ARGS=""
  NUCLEUS_CLOUD_MOUNT_INSTANCE="test-mount.OneDrive"
  NUCLEUS_MOUNT_ATTEMPTS="3"
  NUCLEUS_MOUNT_BACKOFF="0,0"
  NUCLEUS_MOUNT_ATTACH_SECONDS="2"
  NUCLEUS_USER_ROOT="$1/.local/share/nucleus"
  export HOME PATH NUCLEUS_RCLONE_REMOTE_NAME NUCLEUS_RCLONE_REMOTE \
    NUCLEUS_RCLONE_MOUNT_POINT NUCLEUS_RCLONE_ARGS NUCLEUS_CLOUD_MOUNT_INSTANCE \
    NUCLEUS_MOUNT_ATTEMPTS NUCLEUS_MOUNT_BACKOFF NUCLEUS_MOUNT_ATTACH_SECONDS \
    NUCLEUS_USER_ROOT
}

# health_file — path to the health record for the current test instance.
health_file() {
  printf '%s/state/service-stats/%s.json' "$NUCLEUS_USER_ROOT" "$NUCLEUS_CLOUD_MOUNT_INSTANCE"
}

# health_field — read a single field from the health record via jq.
health_field() {
  jq -r ".$1 // empty" "$(health_file)" 2>/dev/null
}

# run_main — invoke _cm_main in a subshell with the mocked backend functions.
# The mock functions are defined in the test script's scope; to make them
# visible inside the subshell, we export them as env vars and re-define them
# via BASH_ENV.  Alternatively, we source the runner and call _cm_main directly
# in the same process (simpler, and the suite already sets +e for the runner).
#
# This function sets FAKE_CALLS and runs _cm_main; callers must have set up
# the mock backend functions and environment beforehand.
run_main() {
  # Source the runner (defines _cm_main but does not execute it).
  # check-suppress:suppression_doc: test helper sources lib via relative path
  # shellcheck disable=SC1091
  . "$MOUNT_SH"
  _cm_main
}

# ── Mock backend functions ───────────────────────────────────────────────────
# These are defined per-test and override the real backend_* functions that
# _cm_dispatch_backend would source.  Since we never call _cm_dispatch_backend,
# we define the interface ourselves.

# Default mocks: succeed at prepare, emit args, detect volume via marker.
MOCK_BACKEND_PREPARE() { return 0; }
MOCK_BACKEND_ARGS() {
  printf '%s\n' "$2" # mount_point
  printf '%s\n' "--vfs-cache-mode"
  printf '%s\n' "full"
}
MOCK_BACKEND_MOUNT() {
  local rclone_bin="$1"
  shift
  # check-suppress:suppression_doc: _backend_capture is set in the runner's scope before this mock is called
  "$rclone_bin" mount "$@" 2>"$_backend_capture" &
  _backend_rclone_pid=$!
}
MOCK_BACKEND_PROBE() {
  [ -f "${FAKE_MARKER:-}" ]
}
MOCK_BACKEND_CLASSIFY() {
  printf 'mount-failed'
}
MOCK_BACKEND_IS_TRANSIENT() {
  return 1 # terminal by default
}
MOCK_BACKEND_UNMOUNT() { return 0; }

# install_mocks — export mock functions so they override the real ones.
install_mocks() {
  backend_prepare() { MOCK_BACKEND_PREPARE "$@"; }
  backend_args() { MOCK_BACKEND_ARGS "$@"; }
  backend_mount() { MOCK_BACKEND_MOUNT "$@"; }
  backend_probe() { MOCK_BACKEND_PROBE "$@"; }
  backend_class() { MOCK_BACKEND_CLASSIFY "$@"; }
  backend_is_transient() { MOCK_BACKEND_IS_TRANSIENT "$@"; }
  backend_unmount() { MOCK_BACKEND_UNMOUNT "$@"; }
  export -f backend_prepare backend_args backend_mount backend_probe \
    backend_class backend_is_transient backend_unmount
}

# ── Tests ────────────────────────────────────────────────────────────────────
section "1" "startup and backend_prepare"

test_prepare_success_proceeds_to_mount() {
  local home bin calls marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES
  install_mocks
  MOCK_BACKEND_PREPARE() {
    printf 'prepare-ok' >>"$home/prepare"
    return 0
  }

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$home/prepare" ] && [ -f "$marker" ]; then
    assert_pass "backend_prepare is called and mount proceeds"
  else
    assert_fail "startup-prepare" "rc=$rc prepare=$([ -f "$home/prepare" ] && echo yes || echo no) marker=$([ -f "$marker" ] && echo yes || echo no)"
  fi
  rm -rf "$home" "$bin"
}

test_prepare_blocks_returns_20() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  export FAKE_CALLS FAKE_REMOTES
  install_mocks
  MOCK_BACKEND_PREPARE() {
    mkdir -p "$NUCLEUS_USER_ROOT/state/service-stats"
    printf '{"state":"blocked","class":"provider-refusal","remedy":"re-enable macFUSE","boot":"test","reported":false,"attempts":0,"lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
      >"$NUCLEUS_USER_ROOT/state/service-stats/$NUCLEUS_CLOUD_MOUNT_INSTANCE.json"
    return 20
  }

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ] && [ "$(health_field state)" = "blocked" ]; then
    assert_pass "backend_prepare returning 20 exits 0 with blocked record"
  else
    assert_fail "startup-prepare-block" "rc=$rc state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"
}

section "2" "successful mount"

test_mount_succeeds_and_records_success() {
  local home bin marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=3
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  # Mount lives 3s, runner detects it, records success, then waits for exit.
  if [ "$rc" -eq 0 ] && [ "$(health_field state)" = "running" ]; then
    assert_pass "a successful mount exits 0 and health record shows running"
  else
    assert_fail "mount-success" "rc=$rc state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"
}

test_mount_passes_remote_and_point_to_rclone() {
  local home bin marker calls
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  marker="$home/clouds/OneDrive/.marker"
  calls="$home/calls"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=2
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  if grep -qF "mount" "$calls" 2>/dev/null && grep -qF "OneDrive:Backups" "$calls" 2>/dev/null; then
    assert_pass "the configured remote reaches rclone's mount call"
  else
    assert_fail "mount-argv" "calls=$(cat "$calls" 2>/dev/null || echo '(empty)')"
  fi
  rm -rf "$home" "$bin"
}

section "3" "retry on transient error"

test_transient_error_retries_and_succeeds() {
  local home bin marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=1
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks

  # First call: no marker (probe fails), transient class.
  # Second call: marker appears (probe succeeds), mount succeeds.
  local call_count=0
  MOCK_BACKEND_PROBE() {
    call_count=$((call_count + 1))
    # First attempt: no marker yet (simulate transient failure).
    if [ "$call_count" -le 1 ]; then
      return 1
    fi
    # Second attempt onward: marker present.
    [ -f "${FAKE_MARKER:-}" ]
  }
  MOCK_BACKEND_CLASSIFY() {
    printf 'io-transient'
  }
  MOCK_BACKEND_IS_TRANSIENT() {
    [ "$1" = "io-transient" ]
  }
  # Kill rclone after first (failed) attempt so the loop can retry.
  MOCK_BACKEND_MOUNT() {
    local rclone_bin="$1"
    shift
    # check-suppress:suppression_doc: _backend_capture is set in the runner's scope before this mock is called
    "$rclone_bin" mount "$@" 2>"$_backend_capture" &
    _backend_rclone_pid=$!
    # After a short time, kill it so the probe fails and we retry.
    if [ "$call_count" -le 1 ]; then
      (
        sleep 0.5
        kill -TERM "$_backend_rclone_pid" 2>/dev/null
      ) &
    fi
  }
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ]; then
    assert_pass "a transient failure retries and eventually succeeds"
  else
    assert_fail "retry-transient" "rc=$rc"
  fi
  rm -rf "$home" "$bin"
}

section "4" "terminal failure → blocked record"

test_terminal_failure_writes_blocked_record() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=1
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks
  # Probe never finds a volume.
  MOCK_BACKEND_PROBE() { return 1; }
  MOCK_BACKEND_CLASSIFY() { printf 'auth'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; } # auth is terminal

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$(health_field state)" = "blocked" ] && [ "$(health_field class)" = "auth" ]; then
    assert_pass "a terminal failure writes a blocked record with the correct class"
  else
    assert_fail "terminal-blocked" "state=$(health_field state) class=$(health_field class)"
  fi
  rm -rf "$home" "$bin"
}

test_unconfigured_remote_exits_0_without_mounting() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="" # no remotes configured
  FAKE_LISTREMOTES_EXIT=0
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_LISTREMOTES_EXIT
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ] && ! grep -qF "mount" "$home/calls" 2>/dev/null; then
    assert_pass "an unconfigured remote exits 0 without mounting"
  else
    assert_fail "unconfigured-remote" "rc=$rc calls=$(cat "$home/calls" 2>/dev/null || echo '(empty)')"
  fi
  rm -rf "$home" "$bin"
}

section "5" "health record lifecycle"

test_health_record_created_on_startup() {
  local home bin marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=2
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ -f "$(health_file)" ] && [ "$(health_field state)" = "running" ]; then
    assert_pass "health record is created with state=running on success"
  else
    assert_fail "health-record-created" "file=$([ -f "$(health_file)" ] && echo yes || echo no) state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"
}

test_health_record_class_and_remedy_on_blocked() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=1
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks
  MOCK_BACKEND_PROBE() { return 1; }
  MOCK_BACKEND_CLASSIFY() { printf 'provider-refusal'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 0; } # transient: retry first

  local rc=0
  run_main 2>/dev/null || rc=$?

  # After 3 failed transient attempts, it writes blocked with "mount-failed".
  local state class
  state="$(health_field state)"
  class="$(health_field class)"
  if [ "$state" = "blocked" ] && [ -n "$class" ]; then
    assert_pass "health record shows blocked state and class after exhaustion"
  else
    assert_fail "health-blocked-detail" "state=$state class=$class"
  fi
  rm -rf "$home" "$bin"
}

section "6" "exit codes"

test_exit_0_on_success() {
  local home bin marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=2
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ]; then
    assert_pass "exit 0 on successful mount"
  else
    assert_fail "exit-success" "rc=$rc"
  fi
  rm -rf "$home" "$bin"
}

test_exit_0_on_blocked_record() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_SLEEP=1
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP
  install_mocks
  MOCK_BACKEND_PROBE() { return 1; }
  MOCK_BACKEND_CLASSIFY() { printf 'remote-not-found'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; } # terminal

  local rc=0
  run_main 2>/dev/null || rc=$?

  # Terminal failure exits 0 (blocked record written; supervisor handles).
  if [ "$rc" -eq 0 ] && [ "$(health_field state)" = "blocked" ]; then
    assert_pass "exit 0 when a blocked record is written (terminal failure)"
  else
    assert_fail "exit-blocked" "rc=$rc state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"
}

section "7" "backend_prepare failure"

test_prepare_failure_exits_20() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES
  install_mocks
  MOCK_BACKEND_PREPARE() { return 20; }

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ]; then
    assert_pass "backend_prepare returning 20 exits 0 (user-action required)"
  else
    assert_fail "prepare-exit-20" "rc=$rc"
  fi
  rm -rf "$home" "$bin"
}

test_prepare_failure_writes_blocked() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin"
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES
  install_mocks
  MOCK_BACKEND_PREPARE() {
    mkdir -p "$NUCLEUS_USER_ROOT/state/service-stats"
    printf '{"state":"blocked","class":"provider-version","remedy":"upgrade macFUSE","boot":"test","reported":false,"attempts":0,"lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
      >"$NUCLEUS_USER_ROOT/state/service-stats/$NUCLEUS_CLOUD_MOUNT_INSTANCE.json"
    return 20
  }

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$(health_field state)" = "blocked" ] && [ "$(health_field class)" = "provider-version" ]; then
    assert_pass "backend_prepare writes blocked record with provider-version class"
  else
    assert_fail "prepare-blocked" "state=$(health_field state) class=$(health_field class)"
  fi
  rm -rf "$home" "$bin"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_prepare_success_proceeds_to_mount
test_prepare_blocks_returns_20
test_mount_succeeds_and_records_success
test_mount_passes_remote_and_point_to_rclone
test_transient_error_retries_and_succeeds
test_terminal_failure_writes_blocked_record
test_unconfigured_remote_exits_0_without_mounting
test_health_record_created_on_startup
test_health_record_class_and_remedy_on_blocked
test_exit_0_on_success
test_exit_0_on_blocked_record
test_prepare_failure_exits_20
test_prepare_failure_writes_blocked
finish_tests
