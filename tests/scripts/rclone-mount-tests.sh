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
#   0 — the ONLY exit for every failure path: backend_prepare failure, a
#       pre-existing block, a terminal class, and exhausted retries. Returning
#       non-zero would be read by the supervisor as "start it again" — the
#       restart storm this runner exists to prevent (src/scripts/services/
#       rclone-mount.sh:33 explains this). Verify failure by reading the health
#       record's state/class/remedy, NEVER by the exit code.
#   <watch_status> — the only non-zero exit: the mount attached, then the rclone
#       process died; its status is propagated verbatim (rclone-mount.sh:179).
#   NOT returned: 1 / 2 / 3 / 20. Those were the contract of an earlier runner.
# shellcheck shell=bash
# SC1090: MOUNT_SH is a runtime variable; SC1091: test-lib.sh resolves via SCRIPT_DIR;
# SC2329: MOCK_BACKEND_* functions are invoked indirectly via exported backend_* wrappers;
# SC2154: _backend_capture is set in the runner's scope before backend_mount is called.
# check-suppress:suppression_doc: test file sources lib via relative path at runtime; variables used by mock functions
# shellcheck disable=SC1090,SC1091,SC2329,SC2154 # reason: runtime-relative source path resolves at test time, and mocks are invoked indirectly
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
MOUNT_SH="$REPO_ROOT/src/scripts/services/rclone-mount.sh"
SERVICES_JSON="$REPO_ROOT/src/modules/services.json"

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
  # The first attempt is the failing one: it attaches nothing and exits at once,
  # so the runner classifies it instead of waiting out the attach budget. The
  # volume only ever appears on the attempt that succeeds. A missing counter file
  # means this is not the retry scenario, so it takes the normal path -- defaulting
  # to the failing path here would silently disarm every later test in the suite.
  if [ -n "${FAKE_ATTEMPTS_FILE:-}" ] && [ -f "$FAKE_ATTEMPTS_FILE" ] &&
    [ "$(head -1 "$FAKE_ATTEMPTS_FILE")" -le 1 ]; then
    exit "${FAKE_FAIL_EXIT:-0}"
  fi
  # Signal volume attachment.
  if [ -n "${FAKE_MARKER:-}" ]; then
    touch "$FAKE_MARKER"
  fi
  # Write any classification-triggering stderr.
  if [ -n "${FAKE_ERRFILE:-}" ] && [ -f "$FAKE_ERRFILE" ]; then
    cat "$FAKE_ERRFILE" >&2
  fi
  # Stay alive until the runner records this mount as running, rather than for a
  # fixed number of seconds.
  #
  # WHY: the runner only probes for NUCLEUS_MOUNT_ATTACH_SECONDS. A mount that
  # outlives that budget can die having never been observed, so the runner
  # classifies a live mount as failed -- the failure behind the mount-success
  # state=blocked flake. Gating the exit on the observation the runner actually
  # makes ties the two together by the runner's own progress rather than by luck:
  # however slowly the loop polls, the mount is still there when it looks. The
  # bound is only a hang guard; if the record never reaches running the test is
  # failing regardless, and must fail rather than block forever.
  if [ -n "${FAKE_EXIT_WHEN_RUNNING:-}" ]; then
    _deadline=$((SECONDS + FAKE_EXIT_WHEN_RUNNING))
    while [ "$SECONDS" -lt "$_deadline" ]; do
      if [ -f "${FAKE_HEALTH_FILE:-}" ] &&
        grep -q '"state"[[:space:]]*:[[:space:]]*"running"' "$FAKE_HEALTH_FILE" 2>/dev/null; then
        break
      fi
      sleep 0.2
    done
  else
    # Live for a while so the runner can "wait" on us.
    sleep "${FAKE_SLEEP:-4}"
  fi
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
  # Clear the lifetime and probe controls before each test. They are exported, so
  # a test that sets one would otherwise hand it to every test that follows and
  # quietly change what their mock rclone or mock probe does.
  unset FAKE_ATTEMPTS_FILE FAKE_EXIT_WHEN_RUNNING FAKE_PROBE_STATE FAKE_PROBE_STATE_FILE
  NUCLEUS_RCLONE_REMOTE="OneDrive:Backups"
  NUCLEUS_RCLONE_MOUNT_POINT="$1/clouds/OneDrive"
  NUCLEUS_RCLONE_ARGS=""
  NUCLEUS_CLOUD_MOUNT_INSTANCE="test-mount.OneDrive"
  NUCLEUS_MOUNT_ATTEMPTS="3"
  NUCLEUS_MOUNT_BACKOFF="0,0"
  NUCLEUS_MOUNT_ATTACH_SECONDS="${3:-2}"
  NUCLEUS_USER_ROOT="$1/.local/share/nucleus"
  # The fake rclone inherits this and gates its own exit on the record, so the
  # mount's lifetime is decided by the runner's observation of it rather than by
  # a clock the two processes happen to share.
  FAKE_HEALTH_FILE="$(printf '%s/state/service-stats/%s.json' "$NUCLEUS_USER_ROOT" "$NUCLEUS_CLOUD_MOUNT_INSTANCE")"
  export HOME PATH NUCLEUS_RCLONE_REMOTE \
    NUCLEUS_RCLONE_MOUNT_POINT NUCLEUS_RCLONE_ARGS NUCLEUS_CLOUD_MOUNT_INSTANCE \
    NUCLEUS_MOUNT_ATTEMPTS NUCLEUS_MOUNT_BACKOFF NUCLEUS_MOUNT_ATTACH_SECONDS \
    NUCLEUS_USER_ROOT FAKE_HEALTH_FILE
}

# health_file — path to the health record for the current test instance.
# One spelling, also handed to the fake rclone by setup_env.
health_file() {
  printf '%s' "$FAKE_HEALTH_FILE"
}

# health_field — read a single field from the health record via jq.
health_field() {
  jq -r ".$1 // empty" "$(health_file)" 2>/dev/null
}

# run_main — invoke _cm_main in a subshell with the mocked backend functions.
# The runner's _cm_main calls `exit` to propagate the runner's exit code; wrapping
# in a subshell confines that exit so finish_tests can still run.
# Pre-set sourcing guards so _cm_dispatch_backend inside _cm_main does not
# overwrite the mock backend_* functions with real implementations.
run_main() {
  # Prevent _cm_dispatch_backend from defining real backend_* functions.
  _NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED=1
  _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED=1
  # Source the runner (defines _cm_main, lib.sh functions, etc.).
  # check-suppress:suppression_doc: test helper sources lib via relative path
  # shellcheck disable=SC1091 # reason: source path resolves at runtime from the test tree
  . "$MOUNT_SH"
  # Ensure backend_* functions exist (install_mocks if tests have not yet
  # called it).  Tests that define mock overrides BEFORE calling run_main
  # have already called install_mocks.
  if ! declare -f backend_prepare >/dev/null 2>&1; then
    install_mocks
  fi
  # Loudness control for the whole mock interface. The call below this
  # function is `run_main 2>/dev/null || rc=$?`, which discards stderr AND
  # disables `set -e` for the entire call chain, so a stub this suite forgot
  # to define would surface only as an empty field in a health record, never
  # as a failure (task-61 finding 1: `backend_remedy` was absent from every
  # install_mocks while the other seven were present). Every other assertion
  # in the suite reads what that call produced, so an omission has to fail
  # here rather than quietly empty them. This does NOT check the production
  # backends: install_mocks defines all eight names itself, so a real backend
  # that dropped one would leave this assertion green. Coverage of the real
  # backends belongs in a suite that does not mock.
  local _cm_missing=''
  local _cm_fn
  for _cm_fn in backend_prepare backend_args backend_mount \
    backend_probe_state backend_class backend_is_transient backend_unmount \
    backend_remedy; do
    if ! declare -f "$_cm_fn" >/dev/null 2>&1; then
      _cm_missing="$_cm_missing $_cm_fn"
    fi
  done
  if [ -n "$_cm_missing" ]; then
    assert_fail "backend-interface-complete" "undefined:${_cm_missing# }"
  fi
  # Export all mock/backend functions so the subshell inherits them.
  # MOCK_BACKEND_REMEDY/backend_remedy are in this list for the same reason as
  # the other seven the runner invokes: an unexported one leaves the child with
  # a command-not-found that run_main's `|| rc=$?` hides.
  export -f MOCK_BACKEND_PREPARE MOCK_BACKEND_ARGS MOCK_BACKEND_MOUNT \
    MOCK_BACKEND_PROBE MOCK_BACKEND_PROBE_STATE MOCK_BACKEND_CLASSIFY \
    MOCK_BACKEND_IS_TRANSIENT MOCK_BACKEND_UNMOUNT MOCK_BACKEND_REMEDY \
    backend_prepare backend_args backend_mount backend_probe \
    backend_probe_state backend_class backend_is_transient backend_unmount \
    backend_remedy
  # Export guard vars so the subshell doesn't re-source backend libs
  # and overwrite the mocks.
  export _NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED=1
  export _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED=1
  export _NUCLEUS_LIB_SOURCED=1
  export _NUCLEUS_SERVICE_HEALTH_SOURCED=1
  # Run _cm_main in a subshell - its exit calls only kill the subshell.
  (_cm_main)
}

# ── Mock backend functions ───────────────────────────────────────────────────
# These are defined per-test and override the real backend_* functions that
# _cm_dispatch_backend would source.  Since we never call _cm_dispatch_backend,
# we define the interface ourselves.

# Default mocks: succeed at prepare, emit args, detect volume via marker.
MOCK_BACKEND_PREPARE() { return 0; }
MOCK_BACKEND_ARGS() {
  printf '%s\n' "$1" # remote
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
# MOCK_BACKEND_PROBE_STATE — the mount table's three-valued answer: present, an
# absent:<reason>, or an unknown:<reason>. The attach wait loop reads this, not
# MOCK_BACKEND_PROBE, because a zero return cannot tell a mount that is present
# from a table that could not be read.
#
# FAKE_PROBE_STATE pins the answer outright, which is how a table that cannot be
# read is modelled. FAKE_PROBE_STATE_FILE mirrors the attempt counter the retry
# test uses: one counter per ATTEMPT, not per probe, so the failing attempt
# misses for its whole budget and the retry is what the test actually exercises.
# With neither set, the answer is derived from the marker the way a readable
# table reports one.
MOCK_BACKEND_PROBE_STATE() {
  if [ -n "${FAKE_PROBE_STATE:-}" ]; then
    printf '%s\n' "$FAKE_PROBE_STATE"
    return
  fi
  if [ -n "${FAKE_PROBE_STATE_FILE:-}" ] && [ -f "$FAKE_PROBE_STATE_FILE" ] &&
    [ "$(head -1 "$FAKE_PROBE_STATE_FILE")" -le 1 ]; then
    printf 'absent:not-listed\n'
    return
  fi
  if [ -f "${FAKE_MARKER:-}" ]; then
    printf 'present\n'
  else
    printf 'absent:not-listed\n'
  fi
}
# MOCK_BACKEND_PROBE — the two-valued view, answering the way
# svc_mount_table_contains answers, so the mock carries the same contract the
# Linux backend's probe does: a table that could not be read returns 0. That
# 0 is correct for a caller that acts on the answer, and it is why the attach
# wait loop cannot use this function to decide a mount is live.
MOCK_BACKEND_PROBE() {
  case "$(MOCK_BACKEND_PROBE_STATE "$@")" in
  present | unknown:*) return 0 ;;
  *) return 1 ;;
  esac
}
MOCK_BACKEND_CLASSIFY() {
  printf 'mount-failed'
}
MOCK_BACKEND_IS_TRANSIENT() {
  return 1 # terminal by default
}
MOCK_BACKEND_UNMOUNT() { return 0; }
# MOCK_BACKEND_REMEDY — the eighth member of the backend interface. It must
# exist: without it the runner's `remedy="$(backend_remedy "$class")"` is a
# command-not-found that the suite's `run_main 2>/dev/null || rc=$?` swallows
# (the `||` also disables `set -e` for the whole call), so the record was
# silently written with remedy:"" and the path had zero coverage. The
# deliberately non-prose value (`remedy:<class>`) makes the exact stub visible
# in an assertion, so a pass proves THIS stub ran rather than any other filler.
MOCK_BACKEND_REMEDY() {
  printf 'remedy:%s' "${1:-<no-class>}"
}

# install_mocks — export mock functions so they override the real ones.
install_mocks() {
  backend_prepare() { MOCK_BACKEND_PREPARE "$@"; }
  backend_args() { MOCK_BACKEND_ARGS "$@"; }
  backend_mount() { MOCK_BACKEND_MOUNT "$@"; }
  backend_probe() { MOCK_BACKEND_PROBE "$@"; }
  backend_probe_state() { MOCK_BACKEND_PROBE_STATE "$@"; }
  backend_class() { MOCK_BACKEND_CLASSIFY "$@"; }
  backend_is_transient() { MOCK_BACKEND_IS_TRANSIENT "$@"; }
  backend_unmount() { MOCK_BACKEND_UNMOUNT "$@"; }
  backend_remedy() { MOCK_BACKEND_REMEDY "$@"; }
  export -f backend_prepare backend_args backend_mount backend_probe \
    backend_probe_state backend_class backend_is_transient backend_unmount \
    backend_remedy
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
  # Override BEFORE run_main so the export captures this version.
  MOCK_BACKEND_PREPARE() {
    printf 'prepare-ok' >>"$home/prepare"
    return 0
  }
  export -f MOCK_BACKEND_PREPARE
  backend_prepare() { MOCK_BACKEND_PREPARE "$@"; }
  export -f backend_prepare

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$home/prepare" ] && [ -f "$marker" ]; then
    assert_pass "backend_prepare is called and mount proceeds"
  else
    assert_fail "startup-prepare" "rc=$rc prepare=$([ -f "$home/prepare" ] && echo yes || echo no) marker=$([ -f "$marker" ] && echo yes || echo no)"
  fi
  rm -rf "$home" "$bin"

  # Restore the default mock so subsequent tests are not affected: the override
  # writes through a `local home` that is unbound once this function returns,
  # so leaving it installed would abort a later caller under `set -u`.
  MOCK_BACKEND_PREPARE() { return 0; }
  export -f MOCK_BACKEND_PREPARE
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
  # Override MOCK_BACKEND_PREPARE to simulate provider-version failure.
  MOCK_BACKEND_PREPARE() {
    mkdir -p "$NUCLEUS_USER_ROOT/state/service-stats"
    printf '{"state":"blocked","class":"provider-refusal","remedy":"re-enable macFUSE","boot":"test","reported":false,"attempts":0,"lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}' \
      >"$NUCLEUS_USER_ROOT/state/service-stats/$NUCLEUS_CLOUD_MOUNT_INSTANCE.json"
    return 20
  }
  export -f MOCK_BACKEND_PREPARE

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ] && [ "$(health_field state)" = "blocked" ]; then
    assert_pass "backend_prepare returning 20 exits 0 with blocked record"
  else
    assert_fail "startup-prepare-block" "rc=$rc state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"

  # Restore the default mock so subsequent tests are not affected.
  MOCK_BACKEND_PREPARE() { return 0; }
  export -f MOCK_BACKEND_PREPARE
}

section "2" "successful mount"

test_mount_succeeds_and_records_success() {
  local home bin marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin" 10
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_EXIT_WHEN_RUNNING=8
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_EXIT_WHEN_RUNNING
  install_mocks
  # Re-export after overriding so the subshell sees the updated function.
  export -f MOCK_BACKEND_PREPARE MOCK_BACKEND_ARGS MOCK_BACKEND_MOUNT \
    MOCK_BACKEND_PROBE MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT \
    MOCK_BACKEND_UNMOUNT backend_prepare backend_args backend_mount \
    backend_probe backend_class backend_is_transient backend_unmount

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
  setup_env "$home" "$bin" 10
  marker="$home/clouds/OneDrive/.marker"
  calls="$home/calls"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_EXIT_WHEN_RUNNING=8
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_EXIT_WHEN_RUNNING
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
  setup_env "$home" "$bin" 5
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_EXIT_WHEN_RUNNING=8
  FAKE_ATTEMPTS_FILE="$home/attempts"
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_EXIT_WHEN_RUNNING FAKE_ATTEMPTS_FILE
  install_mocks

  # One counter per ATTEMPT, not per probe. The previous version counted probes,
  # so the first probe failed and the second succeeded inside a single attempt:
  # the retry path was never taken at all, and the test passed without ever
  # exercising the classification it names. Counting attempts makes attempt 1
  # fail for its whole budget, which is what actually forces the retry.
  #
  # A file-based counter, because a shell local does not survive into the
  # subshell the mocks are exported to. The probe reads the SAME counter, so
  # there is one place that decides which attempt is the failing one.
  local attempts_file="$home/attempts"
  printf '0\n' >"$attempts_file"
  FAKE_PROBE_STATE_FILE="$attempts_file"
  export FAKE_PROBE_STATE_FILE
  MOCK_BACKEND_CLASSIFY() {
    printf 'io-transient'
  }
  MOCK_BACKEND_IS_TRANSIENT() {
    [ "$1" = "io-transient" ]
  }
  # The failing attempt exits at once, so the runner classifies it instead of
  # waiting out the attach budget. The wall-clock killer this replaces raced the
  # runner's own wait by half a second: when it fired first the mount died by
  # SIGTERM and the runner faithfully reported 143, which is the retry-transient
  # flake. Nothing needs killing here -- the runner terminates a mount it has
  # given up on by itself.
  MOCK_BACKEND_MOUNT() {
    local rclone_bin="$1"
    shift
    # check-suppress:suppression_doc: _backend_capture is set in the runner's scope before this mock is called
    local n
    n="$(head -1 "$attempts_file")"
    n="$((n + 1))"
    printf '%s\n' "$n" >"$attempts_file"
    "$rclone_bin" mount "$@" 2>"$_backend_capture" &
    _backend_rclone_pid=$!
  }
  # Re-export all mocks so the subshell sees the updated functions.
  export -f MOCK_BACKEND_PREPARE MOCK_BACKEND_ARGS MOCK_BACKEND_MOUNT \
    MOCK_BACKEND_PROBE MOCK_BACKEND_PROBE_STATE MOCK_BACKEND_CLASSIFY \
    MOCK_BACKEND_IS_TRANSIENT MOCK_BACKEND_UNMOUNT backend_prepare \
    backend_args backend_mount backend_probe backend_probe_state \
    backend_class backend_is_transient backend_unmount
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  # rc alone cannot tell success from failure here. The runner exits 0 on a
  # blocked mount exactly as it does on a running one, so an rc-only assertion
  # passes even with the retry path removed -- it did, until this was made to
  # require what the name claims: a second attempt, and a running record.
  local attempts_made
  attempts_made="$(head -1 "$attempts_file")"
  if [ "$attempts_made" -ge 2 ] && [ "$(health_field state)" = "running" ]; then
    assert_pass "a transient failure retries and eventually succeeds"
  else
    assert_fail "retry-transient" "attempts=$attempts_made state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"

  # Restore default mocks so subsequent tests are not affected. The probe control
  # needs no matching restore: setup_env unsets it before every test, so the file
  # pointer does not follow this one into the tests that come after.
  MOCK_BACKEND_CLASSIFY() { printf 'mount-failed'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  MOCK_BACKEND_MOUNT() {
    local rclone_bin="$1"
    shift
    # check-suppress:suppression_doc: _backend_capture is set in the runner's scope before this mock is called
    "$rclone_bin" mount "$@" 2>"$_backend_capture" &
    _backend_rclone_pid=$!
  }
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT MOCK_BACKEND_MOUNT
}

section "3b" "a mount that dies during startup is classified without waiting out the budget"

test_dead_mount_stops_attach_wait_early() {
  local home bin
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  # A 20s attach budget against a mount that dies instantly. Polling to the end
  # of the budget is correct when the mount is merely slow to show up, so the
  # budget itself cannot shrink to make this test fast -- the loop has to be
  # shown leaving early. Unfixed lands near 20s; fixed lands under 5s.
  setup_env "$home" "$bin" 20
  NUCLEUS_MOUNT_ATTEMPTS="1"
  NUCLEUS_MOUNT_BACKOFF="0,0"
  export NUCLEUS_MOUNT_ATTEMPTS NUCLEUS_MOUNT_BACKOFF

  # The volume never appears, so every probe misses for the whole loop.
  FAKE_PROBE_STATE="absent:not-listed"
  MOCK_BACKEND_CLASSIFY() { printf 'mount-failed'; }
  # Terminal, so one attempt ends the run and the elapsed time is attributable
  # to the attach wait alone rather than to retry backoff.
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  MOCK_BACKEND_MOUNT() {
    # A mount that exits during startup: the defect under test. A subshell, so
    # the pid the runner holds is a real backgrounded child that dies at once.
    (exit 1) 2>"$_backend_capture" &
    _backend_rclone_pid=$!
  }
  export FAKE_PROBE_STATE
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT MOCK_BACKEND_MOUNT
  install_mocks

  local start elapsed
  start=$SECONDS
  # rc is not asserted: the runner exits 0 on a blocked mount as it does on a
  # running one, so it cannot distinguish this outcome. Elapsed time can.
  run_main >/dev/null 2>&1
  elapsed=$((SECONDS - start))

  if [ "$elapsed" -lt 5 ]; then
    assert_pass "a dead mount is classified in ${elapsed}s, not after the 20s budget"
  else
    assert_fail "dead-mount-fast-classify" "elapsed=${elapsed}s budget=20s"
  fi
  rm -rf "$home" "$bin"

  # Restore defaults so the following tests are unaffected. The probe is not
  # among them: setup_env clears FAKE_PROBE_STATE before every test.
  MOCK_BACKEND_CLASSIFY() { printf 'mount-failed'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  MOCK_BACKEND_MOUNT() {
    local rclone_bin="$1"
    shift
    # check-suppress:suppression_doc: _backend_capture is set in the runner's scope before this mock is called
    "$rclone_bin" mount "$@" 2>"$_backend_capture" &
    _backend_rclone_pid=$!
  }
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT MOCK_BACKEND_MOUNT
}

section "3c" "a mount table that cannot be read is not a running mount"

# svc_mount_table_contains still answers 0 for every unknown:* state, because a
# caller that ACTS on the answer must never start a mount on a volume it could
# not disprove. The Linux backend used to expose that predicate as backend_probe;
# the wrapper was an orphan and was deleted, and the backend now answers
# backend_probe_state through svc_mount_table_state, which keeps the third value.
# The attach wait loop was such a caller by position and a reporter by use: it
# set live on the two-valued answer, so a table nobody could read exited the
# loop on its first tick, recorded the service running and successful, and
# deleted the capture file holding the only real evidence. The macOS backend
# never had that input to be unsure about: its probe is a per-path query, and
# anything short of a positive answer was already the not-live answer. The two
# platforms therefore applied opposite conventions to one condition, and a
# mount neither could confirm live came out running on Linux and not-live on
# macOS.
#
# Three separate assertions, because the three are separately wrong on the buggy
# path: the record, the evidence, and the lesson the remedy text teaches.
test_unreadable_mount_table_does_not_record_running() {
  local home bin state class kept evidence
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  # A 2s attach budget against a table that never reads. The budget is the
  # smallest thing that still exercises the poll-to-the-end path, and attempts=1
  # ends the run in the exhaustion record, which is the record a supervisor reads.
  setup_env "$home" "$bin" 2
  NUCLEUS_MOUNT_ATTEMPTS=1
  NUCLEUS_MOUNT_BACKOFF="0,0"
  export NUCLEUS_MOUNT_ATTEMPTS NUCLEUS_MOUNT_BACKOFF
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  # rclone outlives the attach budget. The mount is never in question here, only
  # the read is, so a runner that broke out because the child died would not be
  # exercising the budget at all.
  FAKE_SLEEP=6
  # A distinctive stderr line, so "the capture file survived" is answered by
  # content rather than by "something is left in TMPDIR".
  printf 'fuse: mount attempt left the table unreadable\n' >"$home/rclone.err"
  FAKE_ERRFILE="$home/rclone.err"
  FAKE_PROBE_STATE="unknown:mount-status-32"
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP FAKE_ERRFILE FAKE_PROBE_STATE
  install_mocks
  # Transient, matching how the Linux backend classifies io-transient, so the
  # run reaches the exhaustion record rather than stopping on the first attempt.
  MOCK_BACKEND_IS_TRANSIENT() { [ "$1" = "io-transient" ]; }
  export -f MOCK_BACKEND_IS_TRANSIENT

  local rc=0
  # stdout is captured because the runner NAMES the file it keeps, and that name
  # is the only way to reach it: macOS mktemp ignores TMPDIR for the bare
  # template it uses, so a redirected TMPDIR does not move the capture file.
  run_main >"$home/out" 2>/dev/null || rc=$?

  # rc cannot discriminate: the runner exits 0 on a blocked mount exactly as it
  # does on a running one, which is this suite's standing exit contract.
  state="$(health_field state)"
  class="$(health_field class)"
  kept="$(sed -n 's/.*rclone output kept at //p' "$home/out" | head -1)"

  if [ "$state" != "running" ]; then
    assert_pass "an unreadable mount table is not recorded as a running mount"
  else
    assert_fail "unknown-table-not-running" "state=$state (the attach loop took the success branch)"
  fi
  if [ -n "$kept" ] && [ -f "$kept" ] && grep -qF 'left the table unreadable' "$kept"; then
    assert_pass "the capture file holding rclone's output survives the run and is named"
  else
    assert_fail "unknown-table-keeps-capture" "kept='${kept:-<none>}' (expected a file still holding rclone's output)"
  fi
  # The line naming the kept file is a log line, and log lines rotate. The
  # health record is the only thing that outlives them, so a file nothing can
  # reach is the same as a file that was not kept. Asserted against the path
  # this same run named on stdout, so a pass proves the two agree rather than
  # proving some non-empty string was stored.
  evidence="$(health_field evidence)"
  if [ -n "$evidence" ] && [ "$evidence" = "$kept" ]; then
    assert_pass "the health record points at the capture file the run kept"
  else
    assert_fail "unknown-table-evidence-field" "evidence='${evidence:-<none>}' kept='${kept:-<none>}'"
  fi
  if [ "$class" = "io-transient" ]; then
    assert_pass "an unreadable mount table is classified io-transient, not mount-failed"
  else
    assert_fail "unknown-table-class" "class=$class (expected io-transient)"
  fi
  # The kept file lives in the system temp dir, outside the test's own tree, so
  # it is removed here or it outlives the suite.
  if [ -n "$kept" ]; then
    rm -f "$kept"
  fi
  rm -rf "$home" "$bin"
}

section "3e" "the evidence pointer does not outlive the record that needs it"

# The other half of the pointer's lifecycle. A run that keeps a capture file has
# to say where, and a run that reaches running has to stop saying so: the field
# is a pointer into the failure evidence, and a healthy instance has no failure
# to point at. Left in place, it outlives the record that made it true and sends
# whoever reads the record after a recovery to look for a file the record no
# longer has anything to do with.
test_successful_mount_clears_a_stale_evidence_pointer() {
  local home bin marker state evidence
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  # An attach budget long enough for the mount to be seen, and the marker that
  # makes the probe answer present: the same shape as the section 2 success
  # cases, which is the only thing in this suite that drives a running mount.
  setup_env "$home" "$bin" 10
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_EXIT_WHEN_RUNNING=8
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_EXIT_WHEN_RUNNING
  install_mocks

  # The pointer an earlier run would have left. The path names nothing that
  # exists, and nothing this run creates or deletes, so the assertion below can
  # only be answered by the field being cleared.
  # check-suppress:suppression_doc: test helper sources lib via a runtime repo path
  # shellcheck disable=SC1091 # reason: source path resolves at runtime from the test tree
  . "$REPO_ROOT/src/scripts/lib/service-health.sh"
  svc_health_set "$NUCLEUS_CLOUD_MOUNT_INSTANCE" evidence "\"$home/left-over\""

  # WHY this guard is a field check and not a return-code check: a value jq
  #   cannot parse makes svc_health_set return 1, and under `set -e` that aborts
  #   the suite on the line above — loud, not vacuous. What does pass vacuously
  #   is a seed jq accepts and stores nothing, which is what this catches.
  [ -n "$(svc_health_get "$NUCLEUS_CLOUD_MOUNT_INSTANCE" evidence)" ] ||
    assert_fail "stale-evidence-not-seeded" "the seeded pointer never landed, so the clear asserted below would pass on an empty field"

  local rc=0
  run_main 2>/dev/null || rc=$?

  state="$(health_field state)"
  evidence="$(health_field evidence)"
  # state is part of the condition because an empty field is also what a run
  # that never attached leaves behind: nothing writes evidence except the
  # retention branch, so without requiring the running record this assertion
  # would pass on a mount that never mounted.
  if [ "$state" = "running" ] && [ -z "$evidence" ]; then
    assert_pass "a successful mount clears a stale evidence pointer"
  else
    assert_fail "running-keeps-stale-evidence" "state=$state evidence='${evidence:-<none>}' (expected a running record with no evidence pointer)"
  fi
  rm -rf "$home" "$bin"
}

section "3f" "a kept file survives a later attempt that removes only its own"

# The limit of a single-field pointer, pinned. The field names the most recent
# file kept; this case is about the file an earlier attempt kept, which a later
# attempt's own cleanup must not strand. A clear on the cleanup branch would
# leave the record blocked with no pointer while the file it used to name still
# sits on disk, so the assertion below is the one that goes red if such a clear
# is ever added.
test_removing_this_attempts_file_keeps_an_earlier_pointer() {
  local home bin attempts_file kept evidence
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin" 2
  NUCLEUS_MOUNT_ATTEMPTS=3
  NUCLEUS_MOUNT_BACKOFF="0,0"
  export NUCLEUS_MOUNT_ATTEMPTS NUCLEUS_MOUNT_BACKOFF
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  # The child outlives the attach budget, so every attempt ends on the budget
  # and reaches the retention branch rather than the early child-death break.
  FAKE_SLEEP=6
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP

  # One counter per ATTEMPT, the same device the retry test uses: a shell local
  # does not survive into the subshell the mocks are exported to. The mount
  # increments it, the probe reads it.
  attempts_file="$home/attempts"
  printf '0\n' >"$attempts_file"
  MOCK_BACKEND_MOUNT() {
    local rclone_bin="$1"
    shift
    # check-suppress:suppression_doc: _backend_capture is set in the runner's scope before this mock is called
    local n
    n="$(head -1 "$attempts_file")"
    printf '%s\n' "$((n + 1))" >"$attempts_file"
    "$rclone_bin" mount "$@" 2>"$_backend_capture" &
    _backend_rclone_pid=$!
  }
  # Attempt 1 cannot read the mount table and keeps its capture file. Attempts 2
  # and 3 read it fine and report the mount absent, so each of them removes its
  # own capture file on the retention branch's other arm.
  MOCK_BACKEND_PROBE_STATE() {
    if [ "$(head -1 "$attempts_file")" -le 1 ]; then
      printf 'unknown:mount-status-32\n'
    else
      printf 'absent:not-listed\n'
    fi
  }
  MOCK_BACKEND_PROBE() {
    case "$(MOCK_BACKEND_PROBE_STATE "$@")" in
    present | unknown:*) return 0 ;;
    *) return 1 ;;
    esac
  }
  # Every class transient, so attempts 2 and 3 retry instead of blocking on the
  # first readable answer and the run reaches the exhaustion record.
  MOCK_BACKEND_IS_TRANSIENT() { return 0; }
  export -f MOCK_BACKEND_MOUNT MOCK_BACKEND_PROBE MOCK_BACKEND_PROBE_STATE \
    MOCK_BACKEND_IS_TRANSIENT
  install_mocks

  local rc=0
  # rc cannot discriminate: the runner exits 0 on a blocked mount exactly as it
  # does on a running one, which is this suite's standing exit contract.
  run_main >"$home/out" 2>/dev/null || rc=$?

  local state kept_lines
  state="$(health_field state)"
  evidence="$(health_field evidence)"
  kept="$(sed -n 's/.*rclone output kept at //p' "$home/out" | head -1)"
  # WHY the `||`: grep -c prints the count and returns 1 on no match, so the
  #   branch fires there and on a read failure alike; 0 is right for both.
  kept_lines="$(grep -c 'rclone output kept at' "$home/out" 2>/dev/null)" || kept_lines=0
  # All three parts are needed. A record that never went blocked, or a run that
  # kept nothing, would both leave an empty field and satisfy a weaker form of
  # this assertion; the file check is what proves the pointer still resolves to
  # something on disk rather than to a name nothing wrote.
  if [ "$state" = "blocked" ] && [ "$kept_lines" = "1" ] &&
    [ -n "$evidence" ] && [ "$evidence" = "$kept" ] && [ -f "$evidence" ]; then
    assert_pass "removing this attempt's file leaves an earlier kept file reachable"
  else
    assert_fail "cleanup-strands-kept-file" "state=$state kept_lines=$kept_lines evidence='${evidence:-<none>}' kept='${kept:-<none>}'"
  fi
  if [ -n "$evidence" ]; then
    rm -f "$evidence"
  fi
  rm -rf "$home" "$bin"

  # Restore the defaults so the following tests are unaffected.
  MOCK_BACKEND_MOUNT() {
    local rclone_bin="$1"
    shift
    # check-suppress:suppression_doc: _backend_capture is set in the runner's scope before this mock is called
    "$rclone_bin" mount "$@" 2>"$_backend_capture" &
    _backend_rclone_pid=$!
  }
  MOCK_BACKEND_PROBE_STATE() {
    if [ -n "${FAKE_PROBE_STATE:-}" ]; then
      printf '%s\n' "$FAKE_PROBE_STATE"
      return
    fi
    if [ -n "${FAKE_PROBE_STATE_FILE:-}" ] && [ -f "$FAKE_PROBE_STATE_FILE" ] &&
      [ "$(head -1 "$FAKE_PROBE_STATE_FILE")" -le 1 ]; then
      printf 'absent:not-listed\n'
      return
    fi
    if [ -f "${FAKE_MARKER:-}" ]; then
      printf 'present\n'
    else
      printf 'absent:not-listed\n'
    fi
  }
  MOCK_BACKEND_PROBE() {
    case "$(MOCK_BACKEND_PROBE_STATE "$@")" in
    present | unknown:*) return 0 ;;
    *) return 1 ;;
    esac
  }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  export -f MOCK_BACKEND_MOUNT MOCK_BACKEND_PROBE MOCK_BACKEND_PROBE_STATE \
    MOCK_BACKEND_IS_TRANSIENT
  install_mocks
}

section "3d" "the exhaustion record keeps the last attempt's own class"

# The exhaustion record is the one a supervisor reads after a run has given up,
# and it is the only place the last attempt's diagnosis is still reachable: a
# transient attempt writes no health record of its own, so the classification
# the loop last assigned is the only one that carries forward. It used to be
# written from a hardcoded class whatever rclone's own output had said, so a run
# whose last attempt was told the failure was transient came out as mount-failed,
# and the operator was sent to the remote instead of at the read the runner made.
test_exhaustion_keeps_the_last_attempt_class() {
  local home bin state class
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  # A 2s attach budget and two attempts: enough to run out of attempts, and
  # short enough that the retry path is the one being taken.
  setup_env "$home" "$bin" 2
  NUCLEUS_MOUNT_ATTEMPTS=2
  NUCLEUS_MOUNT_BACKOFF="0,0"
  export NUCLEUS_MOUNT_ATTEMPTS NUCLEUS_MOUNT_BACKOFF
  FAKE_MARKER="$home/clouds/OneDrive/.marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  # The child outlives the attach budget, so the attach wait ends on the budget
  # and every attempt reaches classification. A child that died instead would be
  # testing a different path.
  FAKE_SLEEP=6
  # rclone's own stderr. The fake rclone fixture reads this file and writes it to
  # the captured stderr (the `cat "$FAKE_ERRFILE" >&2` at line 68 of this file),
  # and nothing downstream consumes that content: install_mocks replaces
  # backend_class with MOCK_BACKEND_CLASSIFY, so the class comes from the stub
  # below rather than from this line. The stub is the honest choice because what
  # this test is about is the exhaustion record inheriting the last attempt's
  # class, so the class has to be the one thing held under the test's control;
  # letting a real classifier read rclone's output would be testing the
  # classifier instead of the record.
  printf 'fuse: transient I/O error talking to the remote endpoint\n' >"$home/rclone.err"
  FAKE_ERRFILE="$home/rclone.err"
  # A readable table that reports the mount as absent. The run believes that
  # answer and still runs out of attempts, which is the point: the read here
  # succeeds, so the probe_unknown override does not fire and the runner keeps
  # the classifier's own class rather than guessing one in place of a read that
  # failed.
  FAKE_PROBE_STATE="absent:not-listed"
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_SLEEP FAKE_ERRFILE FAKE_PROBE_STATE
  install_mocks
  # The classifier answers io-transient, as the real backends do when rclone's
  # output names a transient condition.
  MOCK_BACKEND_CLASSIFY() { printf 'io-transient'; }
  # Transient, so the run retries and reaches the exhaustion record instead of
  # blocking on the first attempt.
  MOCK_BACKEND_IS_TRANSIENT() { [ "$1" = "io-transient" ]; }
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT

  local rc=0
  # rc cannot discriminate: the runner exits 0 on a blocked mount exactly as it
  # does on a running one, which is this suite's standing exit contract.
  run_main >/dev/null 2>&1 || rc=$?

  state="$(health_field state)"
  class="$(health_field class)"
  # state is read so the class assertion below cannot pass on a record that was
  # never blocked: an exhaustion run ends blocked, and a run that stopped after
  # one attempt would leave the same class for a different reason.
  if [ "$state" = "blocked" ] && [ "$class" = "io-transient" ]; then
    assert_pass "the exhaustion record keeps the last attempt's own class"
  else
    assert_fail "exhaustion-drops-last-class" "state=$state class=$class (expected a blocked record classed io-transient)"
  fi
  rm -rf "$home" "$bin"

  # Restore the defaults so the following tests are unaffected.
  MOCK_BACKEND_CLASSIFY() { printf 'mount-failed'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT
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
  # Probe never finds a volume. The mount the mock really runs touches FAKE_MARKER,
  # so the answer has to be pinned rather than left to follow the marker.
  FAKE_PROBE_STATE="absent:not-listed"
  MOCK_BACKEND_CLASSIFY() { printf 'auth'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; } # auth is terminal
  # Re-export so the subshell sees updated mock functions.
  export FAKE_PROBE_STATE
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT
  backend_probe() { MOCK_BACKEND_PROBE "$@"; }
  backend_class() { MOCK_BACKEND_CLASSIFY "$@"; }
  backend_is_transient() { MOCK_BACKEND_IS_TRANSIENT "$@"; }
  export -f backend_probe backend_class backend_is_transient

  local rc=0
  run_main 2>/dev/null || rc=$?

  local state class remedy
  state="$(health_field state)"
  class="$(health_field class)"
  remedy="$(health_field remedy)"
  if [ "$state" = "blocked" ] && [ "$class" = "auth" ]; then
    assert_pass "a terminal failure writes a blocked record with the correct class"
  else
    assert_fail "terminal-blocked" "state=$state class=$class"
  fi
  # Remedy must be populated on the failure path by backend_remedy. Exact-value
  # (not merely non-empty): it proves MOCK_BACKEND_REMEDY itself ran with the
  # class, not that some other path happened to fill the field. On pre-fix code
  # backend_remedy does not exist here and the runner's
  # `run_main 2>/dev/null || rc=$?` swallows the command-not-found, so remedy is
  # "" and this assertion fails.
  if [ "$remedy" = "remedy:auth" ]; then
    assert_pass "the failure path populates remedy from backend_remedy"
  else
    assert_fail "terminal-remedy" "remedy='$remedy' (expected 'remedy:auth')"
  fi
  rm -rf "$home" "$bin"

  # Restore default mocks so subsequent tests are not affected. The probe is not
  # among them: setup_env clears FAKE_PROBE_STATE before every test.
  MOCK_BACKEND_CLASSIFY() { printf 'mount-failed'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT
  backend_probe() { MOCK_BACKEND_PROBE "$@"; }
  backend_class() { MOCK_BACKEND_CLASSIFY "$@"; }
  backend_is_transient() { MOCK_BACKEND_IS_TRANSIENT "$@"; }
  export -f backend_probe backend_class backend_is_transient
}

test_unconfigured_remote_exits_0() {
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

  # Runner does not check remote config — mount proceeds regardless.
  # The claim is that the runner does not gate on the remote being configured,
  # so what must be observed is the mount proceeding -- not rc, which is 0
  # whether or not it did.
  if [ "$rc" -eq 0 ] && [ "$(health_field state)" = "running" ]; then
    assert_pass "an unconfigured remote exits 0 (runner does not gate on listremotes)"
  else
    assert_fail "unconfigured-remote" "rc=$rc state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"
}

section "5" "health record lifecycle"

test_health_record_created_on_startup() {
  local home bin marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin" 10
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_EXIT_WHEN_RUNNING=8
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_EXIT_WHEN_RUNNING
  install_mocks
  # Re-export so the subshell sees the correct mock functions.
  export -f MOCK_BACKEND_PREPARE MOCK_BACKEND_ARGS MOCK_BACKEND_MOUNT \
    MOCK_BACKEND_PROBE MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT \
    MOCK_BACKEND_UNMOUNT backend_prepare backend_args backend_mount \
    backend_probe backend_class backend_is_transient backend_unmount

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
  # The mount the mock really runs touches FAKE_MARKER, so the answer has to be
  # pinned rather than left to follow the marker.
  FAKE_PROBE_STATE="absent:not-listed"
  MOCK_BACKEND_CLASSIFY() { printf 'provider-refusal'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 0; } # transient: retry first
  export FAKE_PROBE_STATE

  local rc=0
  run_main 2>/dev/null || rc=$?

  # After 3 failed transient attempts, it writes blocked carrying the last
  # attempt's class.
  local state class remedy
  state="$(health_field state)"
  class="$(health_field class)"
  remedy="$(health_field remedy)"
  if [ "$state" = "blocked" ] && [ -n "$class" ]; then
    assert_pass "health record shows blocked state and class after exhaustion"
  else
    assert_fail "health-blocked-detail" "state=$state class=$class"
  fi
  # The assertion this test is NAMED for. The exhaustion record no longer names
  # a class of its own: it inherits the last attempt's classification, and
  # probe_unknown is the one case where that value is set explicitly rather than
  # carried over. The remedy to assert is therefore the one belonging to
  # whatever class the record ended up holding. Pinning a literal class here
  # would re-assert the hardcoded constant this test used to name, and would go
  # red again the next time the classification improves. The stub emits
  # remedy:<class> (see MOCK_BACKEND_REMEDY), so a pass proves the class the
  # record holds is the one that reached backend_remedy, and a record pairing a
  # class with another class's remedy fails. Task-61 finding 1 was the empty
  # remedy this replaced.
  if [ -n "$class" ] && [ "$remedy" = "remedy:$class" ]; then
    assert_pass "a blocked record carries the remedy for the class it holds"
  else
    assert_fail "blocked-remedy-matches-class" "class='$class' remedy='$remedy'"
  fi
  rm -rf "$home" "$bin"

  # Restore default mocks so subsequent tests are not affected. The probe is not
  # among them: setup_env clears FAKE_PROBE_STATE before every test.
  MOCK_BACKEND_CLASSIFY() { printf 'mount-failed'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT
}

section "6" "exit codes"

test_exit_0_on_success() {
  local home bin marker
  home="$(create_home)"
  bin="$(setup_fake_rclone)"
  setup_env "$home" "$bin" 10
  marker="$home/clouds/OneDrive/.marker"
  FAKE_MARKER="$marker"
  FAKE_CALLS="$home/calls"
  FAKE_REMOTES="OneDrive:"
  FAKE_EXIT_WHEN_RUNNING=8
  export FAKE_MARKER FAKE_CALLS FAKE_REMOTES FAKE_EXIT_WHEN_RUNNING
  install_mocks

  local rc=0
  run_main 2>/dev/null || rc=$?

  if [ "$rc" -eq 0 ] && [ "$(health_field state)" = "running" ]; then
    assert_pass "exit 0 on successful mount"
  else
    assert_fail "exit-success" "rc=$rc state=$(health_field state)"
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
  FAKE_PROBE_STATE="absent:not-listed"
  MOCK_BACKEND_CLASSIFY() { printf 'remote-not-found'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; } # terminal
  export FAKE_PROBE_STATE

  local rc=0
  run_main 2>/dev/null || rc=$?

  # Terminal failure exits 0 (blocked record written; supervisor handles).
  if [ "$rc" -eq 0 ] && [ "$(health_field state)" = "blocked" ]; then
    assert_pass "exit 0 when a blocked record is written (terminal failure)"
  else
    assert_fail "exit-blocked" "rc=$rc state=$(health_field state)"
  fi
  rm -rf "$home" "$bin"

  # Restore default mocks so subsequent tests are not affected. The probe is not
  # among them: setup_env clears FAKE_PROBE_STATE before every test.
  MOCK_BACKEND_CLASSIFY() { printf 'mount-failed'; }
  MOCK_BACKEND_IS_TRANSIENT() { return 1; }
  export -f MOCK_BACKEND_CLASSIFY MOCK_BACKEND_IS_TRANSIENT
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

  # A prepare that returns 20 makes the runner exit 0 without attempting the
  # mount, so the record is never running. rc is 0 here and on every other path,
  # so it cannot distinguish them; what the name claims is that the mount did not
  # proceed. Asserting "not running" rather than a specific state keeps the test
  # honest about which runner wrote the record.
  if [ "$rc" -eq 0 ] && [ "$(health_field state)" != "running" ]; then
    assert_pass "backend_prepare returning 20 exits 0 (user-action required)"
  else
    assert_fail "prepare-exit-20" "rc=$rc state=$(health_field state)"
  fi
  # The default MOCK_BACKEND_PREPARE is a load-time statement (line 180), not
  # part of install_mocks, so this override would otherwise survive into every
  # later test and make prepare fail for them by inheritance.
  MOCK_BACKEND_PREPARE() { return 0; }
  export -f MOCK_BACKEND_PREPARE
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
    printf '{"state":"blocked","class":"provider-version","remedy":"upgrade macFUSE","boot":"test","reported":false,"attempts":0,"lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}' \
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
  # Restore the default (see test_prepare_failure_exits_20): install_mocks does
  # not redefine it, so without this the provider-version override leaks.
  MOCK_BACKEND_PREPARE() { return 0; }
  export -f MOCK_BACKEND_PREPARE
  rm -rf "$home" "$bin"
}

test_prepare_default_restored_after_failure_tests() {
  # Runs immediately after the two prepare-failure tests. Before their fix,
  # MOCK_BACKEND_PREPARE still returned 20 here — the default is a load-time
  # statement, not part of install_mocks — so every test appended afterwards
  # inherited a failing prepare. This assertion is what notices that leak.
  local label="MOCK_BACKEND_PREPARE default restored after the prepare-failure tests"
  if MOCK_BACKEND_PREPARE; then
    assert_pass "$label"
  else
    assert_fail "$label" "override leaked: prepare still returns $?"
  fi
}

# ── Real-backend argument-vector harness (section 22) ────────────────────────
# Sections 1-7 mock backend_mount with a VERBATIM COPY of the production body,
# and setup_fake_rclone records "$*" — every argument joined by spaces.
# A collapsed argument vector is therefore indistinguishable from a correct one:
# the blob still contains the remote and the mount point as substrings, so a
# `grep -qF` assertion passes.  That is how a one-blob argv shipped unnoticed.
#
# This harness closes the hole from both ends:
#   * the recorder keeps each argument on its OWN line (newlines inside an
#     argument are escaped), so arity and element boundaries are observable; and
#   * backend_args and backend_mount are the REAL functions from the backend
#     library, so the argument assembly in rclone-mount.sh is genuinely
#     exercised rather than re-implemented by the mock.

# setup_argv_recorder — rclone shim that records argc and each argument
# verbatim, escaping embedded newlines so one argument never spans two lines.
setup_argv_recorder() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
{
  printf 'argc=%d\n' "$#"
  for _a in "$@"; do
    printf 'arg=<%s>\n' "${_a//$'\n'/\\n}"
  done
} >>"$ARGV_FILE"
if [ -n "${FAKE_MARKER:-}" ]; then touch "$FAKE_MARKER"; fi
sleep 1
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s' "$dir"
}

# run_main_real_backend — run _cm_main with the REAL backend_args and REAL
# backend_mount from the named backend library, overriding only the
# OS-dependent predicates (probe/class/transient/unmount).
#
# Runs inside a subshell for two reasons: the real functions must not shadow the
# mocks that sections 1-7 rely on, and the darwin and linux libraries define the
# SAME function names, so each backend must be exercised in its own shell.
run_main_real_backend() {
  local backend_lib="$1"
  (
    # Clear the sourcing guards so the real backend library loads.
    unset _NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED
    # check-suppress:suppression_doc: test harness sources a runtime-selected backend library
    # shellcheck disable=SC1090 # reason: backend library path is a runtime parameter
    . "$backend_lib"
    # Override ONLY the OS-dependent predicates; leave backend_args and
    # backend_mount as the real implementations.  backend_prepare is among the
    # predicates: it probes the host's FUSE provider and returns 20 when the
    # installed version needs user action, which would exit before mounting and
    # leave the argument vector unexercised.
    #
    # backend_probe_state is overridden alongside backend_probe because the
    # attach wait loop reads it, and the real Linux implementation would shell
    # out to this host's mount table -- which answers nothing about the fake
    # marker -- instead of the volume these tests mount.
    backend_prepare() { return 0; }
    backend_probe() { [ -f "${FAKE_MARKER:-}" ]; }
    backend_probe_state() {
      if [ -f "${FAKE_MARKER:-}" ]; then
        printf 'present\n'
      else
        printf 'absent:not-listed\n'
      fi
    }
    backend_class() { printf 'mount-failed'; }
    backend_is_transient() { return 1; }
    backend_unmount() { return 0; }
    # Block _cm_dispatch_backend from re-sourcing a backend library, which would
    # replace the predicate overrides above with the real implementations.
    export _NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED=1
    export _NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED=1
    unset _NUCLEUS_RCLONE_MOUNT_SOURCED
    # check-suppress:suppression_doc: test harness sources the runner via a runtime path
    # shellcheck disable=SC1090 # reason: MOUNT_SH resolves at runtime from the test tree
    . "$MOUNT_SH"
    (_cm_main)
  )
}

# argv_field — read a recorded field from the argv file.
argv_field() {
  sed -n "s/^$1=//p" "$ARGV_FILE" | head -1
}

# assert_real_backend_argv — assert the argument vector reaching the recorder.
# Args: $1 = label, $2 = expected remote, $3 = expected mount point.
assert_real_backend_argv() {
  local label="$1" want_remote="$2" want_point="$3"
  local argc
  argc="$(argv_field argc)"

  if [ "${argc:-0}" -lt 4 ]; then
    assert_fail "$label-arity" "expected discrete arguments, got argc=${argc:-0} (collapsed vector)"
    return
  fi
  # A collapsed vector is exactly "an argument containing newlines".  The
  # recorder escapes newlines inside an argument, so a literal \n in a recorded
  # line means one argument spans more than one token.
  if grep -qF '\n' "$ARGV_FILE"; then
    assert_fail "$label-blob" "a recorded argument contains embedded newlines (collapsed vector)"
    return
  fi
  if ! grep -qxF 'arg=<mount>' "$ARGV_FILE"; then
    assert_fail "$label-subcommand" "'mount' is not its own argument"
    return
  fi
  if ! grep -qxF "arg=<$want_remote>" "$ARGV_FILE"; then
    assert_fail "$label-remote" "remote is not a discrete argument"
    return
  fi
  if ! grep -qxF "arg=<$want_point>" "$ARGV_FILE"; then
    assert_fail "$label-mountpoint" "mount point (with spaces) is not one discrete argument"
    return
  fi
  assert_pass "$label: argc=$argc, remote and space-containing mount point are each one argument"
}

# real_backend_case — drive the real backend with a space-containing mount point.
# Args: $1 = backend library basename, $2 = label.
real_backend_case() {
  local backend_name="$1" label="$2"
  local home bin marker point
  home="$(create_home)"
  bin="$(setup_argv_recorder)"
  # A mount point containing SPACES: the case unquoted field splitting would corrupt.
  point="$home/clouds/OneDrive replica with spaces"
  mkdir -p "$point"
  marker="$point/.marker"
  setup_env "$home" "$bin"
  NUCLEUS_RCLONE_MOUNT_POINT="$point"
  NUCLEUS_RCLONE_REMOTE="OneDrive:Backups"
  ARGV_FILE="$home/argv"
  FAKE_MARKER="$marker"
  export NUCLEUS_RCLONE_MOUNT_POINT NUCLEUS_RCLONE_REMOTE ARGV_FILE FAKE_MARKER

  local rc=0
  run_main_real_backend "$REPO_ROOT/src/scripts/lib/mount-backend-$backend_name.sh" 2>/dev/null || rc=$?

  assert_real_backend_argv "$label" "OneDrive:Backups" "$point"
  rm -rf "$home" "$bin"
}

section "22" "mount argument vector (REAL backend_args + REAL backend_mount)"

# The assertion whose absence let a one-blob argv ship: it constrains the
# ARGUMENT VECTOR, not merely that a mount eventually happened.
test_real_backend_argv_darwin() {
  real_backend_case darwin "darwin-backend-argv"
}

test_real_backend_argv_linux() {
  real_backend_case linux "linux-backend-argv"
}

section "23" "declared backoff schedule (single policy, clamped)"

# The runner and the Windows runner consume ONE declared policy
# (services.json cloud-drive.lifecycle.mountRetryBackoffSeconds).  The property that makes a
# cross-host divergence impossible is that every delay the runner sleeps is a value
# that declared list contains.  An extrapolating runner invents values past the end
# of the list, which is both a second policy and a parity break.
#
# Reachability: the retry loop sleeps only while `attempt < attempts`, so with the
# declared values (mountAttempts 3, schedule [20, 40]) both hosts sleep on attempts 1 and 2
# only — inside the list, where they already agree.  The divergence is therefore
# LATENT, not live: it arms the moment `mountAttempts` is raised past len(schedule) + 1.
# The rule is asserted directly below so the landmine cannot arm silently.

# backoff_values — print "<attempt> <seconds>" for each attempt the declared policy
# runs.  Sources the runner in a subshell so _cm_get_backoff is the REAL
# implementation rather than a re-statement of it.
backoff_values() {
  local csv="$1" attempts="$2"
  (
    # Source freshly: a guard left set by an earlier test would otherwise make the
    # subshell inherit an already-sourced runner and silently skip the definition.
    unset _NUCLEUS_RCLONE_MOUNT_SOURCED
    export NUCLEUS_MOUNT_BACKOFF="$csv"
    # shellcheck source=/dev/null # reason: runner path resolved from REPO_ROOT at test time
    . "$MOUNT_SH"
    _cm_parse_backoff
    local a=1
    while [ "$a" -le "$attempts" ]; do
      printf '%s %s\n' "$a" "$(_cm_get_backoff "$a")"
      a=$((a + 1))
    done
  )
}

test_backoff_values_within_declared_schedule() {
  local label="every backoff value is one the schedule declares"
  local csv attempts values bad=""
  csv="$(jq -r '."cloud-drive".lifecycle.mountRetryBackoffSeconds | join(",")' "$SERVICES_JSON")"
  attempts="$(jq -r '."cloud-drive".lifecycle.mountAttempts' "$SERVICES_JSON")"
  # Under `set -e` a bare `values="$(...)"` aborts the whole script when
  # backoff_values returns non-zero, so this guard could never be the thing that
  # reports an empty schedule. The assignment belongs inside the condition.
  if ! values="$(backoff_values "$csv" "$attempts")" || [ -z "$values" ]; then
    assert_fail "$label" "the runner produced no backoff values"
    return
  fi
  local a v
  while IFS=' ' read -r a v; do
    case ",$csv," in
    *",$v,"*) ;;
    *) bad="$bad attempt$a=$v" ;;
    esac
  done <<<"$values"
  if [ -z "$bad" ]; then
    assert_pass "$label"
  else
    assert_fail "$label" "invented (not declared in [$csv]):$bad"
  fi
}

test_backoff_clamps_to_declared_sequence() {
  local label="backoff sequence matches the declared clamp rule"
  local csv attempts values expected
  csv="$(jq -r '."cloud-drive".lifecycle.mountRetryBackoffSeconds | join(",")' "$SERVICES_JSON")"
  attempts="$(jq -r '."cloud-drive".lifecycle.mountAttempts' "$SERVICES_JSON")"
  # Same reachability fix as test_backoff_values_within_declared_schedule.
  if ! values="$(backoff_values "$csv" "$attempts")" || [ -z "$values" ]; then
    assert_fail "$label" "the runner produced no backoff values"
    return
  fi
  # Expected, per the DECLARED rule (services.schema.json mountRetryBackoffSeconds): attempt N
  # uses element N-1, clamped to the last element.  Written independently of the
  # runner so a shared re-statement cannot commute the two.
  local -a declared=()
  IFS=',' read -ra declared <<<"$csv"
  local -a want=()
  local i idx
  i=0
  while [ "$i" -lt "$attempts" ]; do
    idx="$i"
    if [ "$idx" -gt "$((${#declared[@]} - 1))" ]; then
      idx=$((${#declared[@]} - 1))
    fi
    want+=("$((i + 1)) ${declared[$idx]}")
    i=$((i + 1))
  done
  # printf over the array: newline-joined, and the command substitution strips the
  # trailing newline exactly as it does for `values`, so the two are comparable.
  expected="$(printf '%s\n' "${want[@]}")"
  if [ "$values" = "$expected" ]; then
    assert_pass "$label"
  else
    assert_fail "$label" "got [$(printf '%s' "$values" | tr '\n' ';')], declared rule yields [$(printf '%s' "$expected" | tr '\n' ';')]"
  fi
}

test_backoff_schedule_is_nonempty() {
  local label="the declared backoff schedule is non-empty"
  local count
  count="$(jq -r '."cloud-drive".lifecycle.mountRetryBackoffSeconds | length' "$SERVICES_JSON")"
  # An empty schedule subscript-error crashes BOTH runners (POSIX _cm_get_backoff and
  # the Windows [Math]::Min branch), so the schema declares minItems 1 and the runners
  # reject an empty env value.  Asserted as data because the crash is unreachable
  # through the runner's own :? guard.
  if [ "$count" -ge 1 ]; then
    assert_pass "$label"
  else
    assert_fail "$label" "mountRetryBackoffSeconds is empty; both runners subscript-fail on it"
  fi
}

test_backoff_schedule_covers_every_retry() {
  local label="the declared schedule covers every retry the runner performs"
  local count attempts
  count="$(jq -r '."cloud-drive".lifecycle.mountRetryBackoffSeconds | length' "$SERVICES_JSON")"
  attempts="$(jq -r '."cloud-drive".lifecycle.mountAttempts' "$SERVICES_JSON")"
  # The loop retries attempts 1..attempts-1, so a schedule of at least attempts-1
  # entries means every delay the runner sleeps is a declared value by construction
  # and the clamp never has to engage.  This is the invariant that keeps the
  # POSIX/Windows divergence latent; the clamp is the backstop when it is violated.
  if [ "$count" -ge "$((attempts - 1))" ]; then
    assert_pass "$label"
  else
    assert_fail "$label" "attempts=$attempts needs >=$((attempts - 1)) backoff values, schedule has $count"
  fi
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_prepare_success_proceeds_to_mount
test_prepare_blocks_returns_20
test_mount_succeeds_and_records_success
test_mount_passes_remote_and_point_to_rclone
test_transient_error_retries_and_succeeds
test_dead_mount_stops_attach_wait_early
test_unreadable_mount_table_does_not_record_running
test_successful_mount_clears_a_stale_evidence_pointer
test_removing_this_attempts_file_keeps_an_earlier_pointer
test_exhaustion_keeps_the_last_attempt_class
test_terminal_failure_writes_blocked_record
test_unconfigured_remote_exits_0
test_health_record_created_on_startup
test_health_record_class_and_remedy_on_blocked
test_exit_0_on_success
test_exit_0_on_blocked_record
test_prepare_failure_exits_20
test_prepare_failure_writes_blocked
test_prepare_default_restored_after_failure_tests
test_real_backend_argv_darwin
test_real_backend_argv_linux
test_backoff_values_within_declared_schedule
test_backoff_clamps_to_declared_sequence
test_backoff_schedule_is_nonempty
test_backoff_schedule_covers_every_retry
finish_tests
