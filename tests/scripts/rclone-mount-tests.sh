#!/usr/bin/env bash
# rclone-mount.sh — the mount wrapper's exit report, remote guard, stop handling
# and stale-volume pre-flight.
#
# The LaunchAgent sets KeepAlive{SuccessfulExit = false} and rclone runs at
# NOTICE level, so a mount whose volume is destroyed seconds after it attaches
# exits 0 with almost no output and is never retried: the job can be down while
# its log looks healthy. The regressions this guards: a clean exit going
# unreported (and unrecovered), the report losing rclone's status or the mount
# point, the deliberate skip of an unconfigured remote turning into a crash loop,
# a stop request leaving rclone unmounting in the background (which wedges the
# volume for the path), and a new mount landing on a volume that is still there.
# The macFUSE/FSKit classification is macOS-only: off macOS the same failures are
# ordinary ones that keep rclone's status so the supervisor reloads the mount.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
MOUNT_SH="$REPO_ROOT/src/scripts/services/rclone-mount.sh"
# The LaunchAgent label the wrapper records a provider failure against. It is the
# key every service command uses, which is what makes the record useful.
MOUNT_INSTANCE="local.cloud-mount.OneDrive"
# PID of the wrapper the last run_mount_bg call started.

# The suite pins the host it tests. The wrapper scopes the macFUSE/FSKit
# classification to macOS with uname(1), and the marker directory comes from that
# same probe (lib.sh's derive_nucleus_user_root), so the stub and the paths below
# both follow FAKE_UNAME_S: Darwin by default, because every FSKit assertion needs
# it, and Linux for the assertions that pin the other branch. Without the pin the
# suite's result would depend on the machine that runs it.
_suite_bin="$(mktemp -d)"
cat >"$_suite_bin/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Darwin}"
FAKE_UNAME
chmod +x "$_suite_bin/uname"
export PATH="$_suite_bin:$PATH"
trap 'rm -rf "$_suite_bin"' EXIT

# blocked_marker <home> [kernel] — path of the blocked marker the wrapper writes
# for the instance. The directory follows the kernel the stub reports.
blocked_marker() {
  case "${2:-Darwin}" in
  Darwin) printf '%s/Library/Application Support/nucleus/state/service-stats/%s.blocked\n' "$1" "$MOUNT_INSTANCE" ;;
  *) printf '%s/.local/share/nucleus/state/service-stats/%s.blocked\n' "$1" "$MOUNT_INSTANCE" ;;
  esac
}

# Stub bin dir whose rclone records its argv, answers `listremotes` with
# FAKE_REMOTES, and exits with FAKE_MOUNT_STATUS from `mount`. Prints the dir.
setup_fake_rclone() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CALLS"
case "${1-}" in
listremotes)
  printf '%s\n' "${FAKE_REMOTES-}"
  exit "${FAKE_LISTREMOTES_STATUS:-0}"
  ;;
mount)
  exit "${FAKE_MOUNT_STATUS:-0}"
  ;;
esac
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s\n' "$dir"
}

# Stub bin dir whose rclone models a mount that takes time to let go: the unmount
# finishes 2 s after the stop request, and only then does rclone exit 0.
setup_fake_rclone_graceful() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CALLS"
case "${1-}" in
listremotes)
  printf '%s\n' "OneDrive:"
  exit 0
  ;;
mount)
  sleep 30 &
  _sleeper=$!
  # The unmount work a stop request must not cut short.
  trap 'kill "$_sleeper"; sleep 2; exit 0' TERM
  if wait "$_sleeper"; then :; fi
  exit 0
  ;;
esac
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s\n' "$dir"
}

# Stub bin dir whose rclone ignores stop requests and only finishes its own
# unmount work a few seconds later, exiting with FAKE_STUCK_STATUS. Lets the
# wrapper be observed staying with a mount that is slow to let go instead of
# returning early. The mount records its own PID and its sleeper's in FAKE_PIDS.
setup_fake_rclone_stuck() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CALLS"
case "${1-}" in
listremotes)
  printf '%s\n' "OneDrive:"
  exit 0
  ;;
mount)
  printf '%s\n' "$$" >>"$FAKE_PIDS"
  trap '' TERM
  sleep 4 &
  _sleeper=$!
  printf '%s\n' "$_sleeper" >>"$FAKE_PIDS"
  if wait "$_sleeper"; then :; fi
  exit "${FAKE_STUCK_STATUS:-0}"
  ;;
esac
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s\n' "$dir"
}

# Stub bin dir whose rclone parks: it starts, attaches nothing, and writes nothing
# to the console, which is how macFUSE leaves a mount behind its modal "unexpected
# error" dialog (observed parked for 3573 s). It ends on a stop signal, the way the
# dialog ends when its process is signalled.
setup_fake_rclone_parked() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CALLS"
case "${1-}" in
listremotes)
  printf '%s\n' "OneDrive:"
  exit 0
  ;;
mount)
  trap 'exit 143' TERM
  while :; do sleep 1; done
  ;;
esac
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s\n' "$dir"
}

# Stub bin dir whose rclone is refused by macFUSE's FSKit provider: it reports the
# provider's own message and exits non-zero, which is how the same failure ends
# when FSKit answers immediately instead of parking the attempt.
setup_fake_rclone_refused() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CALLS"
case "${1-}" in
listremotes)
  printf '%s\n' "OneDrive:"
  exit 0
  ;;
mount)
  printf '%s\n' 'MFMount: MFMount(_:_:_:_:): File system extension not enabled' >&2
  printf '%s\n' 'fuse: mount failed with error: 4' >&2
  exit 3
  ;;
esac
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s\n' "$dir"
}

# Stub bin dir whose rclone attaches a volume and keeps serving it until it exits.
# Lets the attach be observed (and the blocked marker be cleared) before the mount
# ends on its own.
setup_fake_rclone_attached() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rclone" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CALLS"
case "${1-}" in
listremotes)
  printf '%s\n' "OneDrive:"
  exit 0
  ;;
mount)
  trap 'exit 0' TERM
  sleep 6
  exit 0
  ;;
esac
exit 0
STUB
  chmod +x "$dir/rclone"
  printf '%s\n' "$dir"
}

# Add a fake mount table (`mount`) and volume release (`diskutil`) to a stub bin
# dir. The table lists FAKE_MOUNT_PATH while FAKE_ATTACHED exists; diskutil clears
# that file only while FAKE_DISKUTIL_OK exists, and fails otherwise.
# FAKE_HANG_ONCE makes the first probe hang instead (a volume that cannot even be
# listed), which the wrapper must bound rather than block on.
add_fake_mount_table() {
  local dir="$1"
  cat >"$dir/mount" <<'STUB'
#!/usr/bin/env bash
if [ -n "${FAKE_HANG_ONCE-}" ] && [ ! -e "$FAKE_HANG_ONCE" ]; then
  : >"$FAKE_HANG_ONCE"
  exec sleep 60
fi
if [ -e "$FAKE_ATTACHED" ]; then
  printf 'fake://vol on %s (fake, nodev)\n' "$FAKE_MOUNT_PATH"
fi
STUB
  cat >"$dir/diskutil" <<'STUB'
#!/usr/bin/env bash
if [ -e "$FAKE_DISKUTIL_OK" ]; then
  rm -f "$FAKE_ATTACHED"
  exit 0
fi
exit 1
STUB
  chmod +x "$dir/mount" "$dir/diskutil"
}

# Run the mount wrapper against the fake rclone, with the wrapper's stderr left
# on the caller's stream so `2>&1` can capture the report.
# Args: <home> <bin> <calls> <remotes> <mount_status> [listremotes_status]
run_mount() {
  local home="$1" bin="$2" calls="$3" remotes="$4" mount_status="$5"
  local list_status="${6:-0}"
  HOME="$home" PATH="$bin:$PATH" \
    FAKE_CALLS="$calls" FAKE_REMOTES="$remotes" \
    FAKE_MOUNT_STATUS="$mount_status" FAKE_LISTREMOTES_STATUS="$list_status" \
    NUCLEUS_RCLONE_REMOTE_NAME="OneDrive" \
    NUCLEUS_RCLONE_REMOTE="OneDrive:Backups" \
    NUCLEUS_RCLONE_MOUNT_POINT="$home/clouds/OneDrive" \
    NUCLEUS_RCLONE_ARGS='' \
    NUCLEUS_CLOUD_MOUNT_INSTANCE="$MOUNT_INSTANCE" \
    bash "$MOUNT_SH" 1>/dev/null
}

# Start the wrapper in the background so a stop request can be sent while it is
# mounting, which a foreground run cannot express. The wrapper stays a child of
# this shell, so `wait` works on it and its PID can be signalled; the PID is left
# in RUN_MOUNT_BG_PID — a command substitution would run this in a subshell and
# leave the wrapper unreapable by the caller.
# Args: <home> <bin> <calls> <errfile> [pids]
run_mount_bg() {
  local home="$1" bin="$2" calls="$3" errfile="$4" pids="${5:-}"
  HOME="$home" PATH="$bin:$PATH" \
    FAKE_CALLS="$calls" FAKE_PIDS="$pids" FAKE_REMOTES="OneDrive:" \
    FAKE_MOUNT_STATUS=0 FAKE_LISTREMOTES_STATUS=0 \
    NUCLEUS_RCLONE_REMOTE_NAME="OneDrive" \
    NUCLEUS_RCLONE_REMOTE="OneDrive:Backups" \
    NUCLEUS_RCLONE_MOUNT_POINT="$home/clouds/OneDrive" \
    NUCLEUS_RCLONE_ARGS='' \
    NUCLEUS_CLOUD_MOUNT_INSTANCE="$MOUNT_INSTANCE" \
    bash "$MOUNT_SH" 1>/dev/null 2>"$errfile" &
  RUN_MOUNT_BG_PID=$!
}

# pid_running <pid> — whether the PID is still running. Returns 0 when it is.
# Only used where the answer decides whether work is still in progress: a PID
# that has already exited answers 0 until this shell reaps it.
pid_running() {
  if kill -0 "$1" 2>/dev/null; then
    return 0
  fi
  return 1
}

# wait_bounded <pid> <seconds> — wait for a child, killing it after the bound so a
# wrapper that never finishes fails the suite instead of hanging it. A bare `wait`
# has no timeout, and polling kill -0 cannot tell a zombie from a running process.
wait_bounded() {
  local pid="$1" bound="$2" watchdog="" status=0
  (
    sleep "$bound"
    # check-suppress:suppression_doc: the child may already have finished; the bound is what this watchdog reports.
    kill -KILL "$pid" 2>/dev/null
  ) &
  watchdog=$!
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  # check-suppress:suppression_doc: the watchdog may have fired and exited already; the reap of a finished watcher changes nothing.
  kill -TERM "$watchdog" 2>/dev/null || true
  return "$status"
}

section "1" "mount exit reporting"

test_failed_mount_exit_is_reported_and_propagated() {
  local home bin calls rc=0 err="" reported=false named=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  calls="$home/calls"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 3 2>&1)" || rc=$?
  case "$err" in *"exited with status 3 after "*"s."*) reported=true ;; esac
  case "$err" in *"$home/clouds/OneDrive"*) named=true ;; esac
  if [ "$rc" -eq 3 ] && [ "$reported" = true ] && [ "$named" = true ]; then
    assert_pass "a failed mount exits with rclone's status and names the mount point"
  else
    assert_fail "rclone-mount-exit-status" \
      "rc=$rc reported=$reported named=$named stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

test_clean_mount_exit_is_still_reported() {
  local home bin calls rc=0 err="" reported=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  calls="$home/calls"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  case "$err" in *"exited with status 0 after "*"without a live mount"*) reported=true ;; esac
  # WHY: exit 1, not 0 — a volume destroyed seconds after it attaches ends in
  #   rclone's exit 0, which KeepAlive{SuccessfulExit:false} never retries, so the
  #   wrapper has to fail for the agent to reload the mount.
  if [ "$rc" -eq 1 ] && [ "$reported" = true ]; then
    assert_pass "a clean exit that leaves no mount is reported and fails so the agent retries"
  else
    assert_fail "rclone-mount-clean-exit" "rc=$rc reported=$reported stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

test_remote_and_mount_point_reach_rclone() {
  local home bin calls rc=0 forwarded=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  calls="$home/calls"
  run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1 || rc=$?
  if grep -Fq "mount OneDrive:Backups $home/clouds/OneDrive" "$calls"; then
    forwarded=true
  fi
  if [ "$rc" -eq 1 ] && [ "$forwarded" = true ]; then
    assert_pass "the configured remote and mount point reach rclone's mount call"
  else
    assert_fail "rclone-mount-argv" \
      "rc=$rc forwarded=$forwarded calls=$(cat "$calls")"
  fi
  rm -rf "$home" "$bin"
}

section "2" "remote guard"

test_unconfigured_remote_skips_without_a_restart_loop() {
  local home bin calls rc=0 err="" skipped=false mounted=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  calls="$home/calls"
  err="$(run_mount "$home" "$bin" "$calls" "gdrive:" 0 2>&1)" || rc=$?
  case "$err" in *"not configured; mount skipped."*) skipped=true ;; esac
  case "$err" in *"mount OneDrive:Backups"*) mounted=true ;; esac
  if [ "$rc" -eq 0 ] && [ "$skipped" = true ] && [ "$mounted" = false ]; then
    assert_pass "an unconfigured remote is skipped with exit 0 and never mounted"
  else
    assert_fail "rclone-mount-unconfigured" \
      "rc=$rc skipped=$skipped mounted=$mounted stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

test_failing_remote_listing_fails_the_wrapper() {
  local home bin calls rc=0 err="" died=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  calls="$home/calls"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 9 2>&1)" || rc=$?
  case "$err" in *"failed to list rclone remotes for 'OneDrive' mount"*) died=true ;; esac
  if [ "$rc" -eq 1 ] && [ "$died" = true ]; then
    assert_pass "a failing remote listing fails the wrapper instead of mounting nothing"
  else
    assert_fail "rclone-mount-listremotes" "rc=$rc died=$died stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

section "3" "stop requests"

# A stop request interrupts the wrapper's 'wait' with status 128+signo. Returning
# that status exits while rclone is still unmounting, which is what leaves the
# volume wedged, so the wrapper has to keep waiting instead.
test_stop_request_waits_for_rclone_to_finish() {
  local home bin calls errfile pid="" rc=0 waited=false quiet=true elapsed=0 started_at=0
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_graceful)"
  calls="$home/calls"
  errfile="$home/err"
  : >"$calls"
  started_at="$SECONDS"
  run_mount_bg "$home" "$bin" "$calls" "$errfile"
  pid="$RUN_MOUNT_BG_PID"
  sleep 1
  kill -TERM "$pid"
  sleep 0.5
  if pid_running "$pid"; then waited=true; fi
  wait_bounded "$pid" 10 || rc=$?
  elapsed=$((SECONDS - started_at))
  if grep -q "cloud-drives" "$errfile"; then quiet=false; fi
  if [ "$rc" -eq 0 ] && [ "$waited" = true ] && [ "$quiet" = true ] && [ "$elapsed" -ge 2 ]; then
    assert_pass "a stop request waits for rclone to finish and exits 0 without noise"
  else
    assert_fail "rclone-mount-stop-waits" \
      "rc=$rc still-running-after-TERM=$waited quiet=$quiet elapsed=${elapsed}s stderr=[$(cat "$errfile")]"
  fi
  rm -rf "$home" "$bin"
}

# A mount that is slow to stop must not be abandoned: the wrapper stays with
# rclone while it finishes and reports the status it finally exited with.
test_slow_stop_is_waited_out_and_reported() {
  local home bin calls errfile pids pid="" rc=0 waited=false reported=false named=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_stuck)"
  calls="$home/calls"
  errfile="$home/err"
  pids="$home/pids"
  : >"$calls"
  : >"$pids"
  export FAKE_STUCK_STATUS=3
  run_mount_bg "$home" "$bin" "$calls" "$errfile" "$pids"
  pid="$RUN_MOUNT_BG_PID"
  sleep 1
  kill -TERM "$pid"
  sleep 2
  if pid_running "$pid"; then waited=true; fi
  wait_bounded "$pid" 15 || rc=$?
  case "$(cat "$errfile")" in *"(stop requested)"*) reported=true ;; esac
  case "$(cat "$errfile")" in *"$home/clouds/OneDrive"*) named=true ;; esac
  if [ "$waited" = true ] && [ "$rc" -eq 0 ] && [ "$reported" = true ] && [ "$named" = true ]; then
    assert_pass "a mount that is slow to stop is waited out and its exit is reported"
  else
    assert_fail "rclone-mount-stop-slow" \
      "rc=$rc still-running-after-TERM=$waited reported=$reported named=$named stderr=[$(cat "$errfile")]"
  fi
  unset FAKE_STUCK_STATUS
  rm -rf "$home" "$bin"
}

# A mount killed outright while it is stopping exits with a status above 128, and
# bash hands that status back on every later wait for the same (already reaped)
# child, so the stop wait never sees a status it can break on.
# WHY reported rather than asserted: the wrapper spinning here is a defect in
#   src/scripts/services/rclone-mount.sh, not a contract of the wrapper. This case
#   turns into the assertion it wants to be as soon as that defect is fixed, and
#   assert_skip keeps the defect visible in the tally until then.
test_mount_killed_while_stopping_does_not_spin_the_wrapper() {
  local home bin calls errfile pids pid="" rclone_pid="" sleeper_pid="" rc=0
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_stuck)"
  calls="$home/calls"
  errfile="$home/err"
  pids="$home/pids"
  : >"$calls"
  : >"$pids"
  run_mount_bg "$home" "$bin" "$calls" "$errfile" "$pids"
  pid="$RUN_MOUNT_BG_PID"
  sleep 1
  kill -TERM "$pid"
  sleep 2
  rclone_pid="$(sed -n 1p "$pids")"
  sleeper_pid="$(sed -n 2p "$pids")"
  # The way a mount ends when launchd, an OOM kill or 'kill -9' ends it.
  kill -KILL "$rclone_pid"
  wait_bounded "$pid" 5 || rc=$?
  # check-suppress:suppression_doc: cleanup of the stub's sleeper; it may have exited with its mount.
  kill -KILL "$sleeper_pid" 2>/dev/null || true
  if [ "$rc" -eq 137 ]; then
    assert_skip "a mount killed while it is stopping lets the wrapper return" \
      "wrapper still waiting 5s after rclone was killed (defect: 'wait' returns the cached 137 for an already-reaped child, so the stop wait never ends and only launchd's ExitTimeOut kills it)"
  else
    assert_pass "a mount killed while it is stopping lets the wrapper return"
  fi
  rm -rf "$home" "$bin"
}

section "4" "stale volume pre-flight"

test_attached_volume_is_released_before_mounting() {
  local home bin calls rc=0 err="" warned=false mounted=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  add_fake_mount_table "$bin"
  calls="$home/calls"
  : >"$calls"
  export FAKE_ATTACHED="$home/attached" FAKE_DISKUTIL_OK="$home/diskutil-ok"
  export FAKE_MOUNT_PATH="$home/clouds/OneDrive"
  : >"$FAKE_ATTACHED"
  : >"$FAKE_DISKUTIL_OK"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  case "$err" in *"a volume is still attached at '$home/clouds/OneDrive'"*) warned=true ;; esac
  if grep -Fq "mount OneDrive:Backups $home/clouds/OneDrive" "$calls"; then mounted=true; fi
  if [ "$warned" = true ] && [ "$mounted" = true ] && [ ! -e "$FAKE_ATTACHED" ]; then
    assert_pass "a volume left attached is released before rclone mounts over it"
  else
    assert_fail "rclone-mount-stale-volume-released" \
      "rc=$rc warned=$warned mounted=$mounted released=$([ -e "$FAKE_ATTACHED" ] && echo no || echo yes) stderr=[$err]"
  fi
  unset FAKE_ATTACHED FAKE_DISKUTIL_OK FAKE_MOUNT_PATH
  rm -rf "$home" "$bin"
}

test_unreleasable_volume_refuses_the_mount() {
  local home bin calls rc=0 err="" refused=false remedy=false mounted=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  add_fake_mount_table "$bin"
  calls="$home/calls"
  : >"$calls"
  export FAKE_ATTACHED="$home/attached" FAKE_MOUNT_PATH="$home/clouds/OneDrive"
  : >"$FAKE_ATTACHED"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  case "$err" in *"refusing to mount over it"*) refused=true ;; esac
  case "$err" in *"sudo umount -f \"$home/clouds/OneDrive\""*) remedy=true ;; esac
  if grep -Fq "mount OneDrive:Backups" "$calls"; then mounted=true; fi
  if [ "$rc" -eq 1 ] && [ "$refused" = true ] && [ "$remedy" = true ] && [ "$mounted" = false ]; then
    assert_pass "a volume that cannot be released refuses the mount and names the remedy"
  else
    assert_fail "rclone-mount-stale-volume-refused" \
      "rc=$rc refused=$refused remedy=$remedy mounted=$mounted stderr=[$err]"
  fi
  unset FAKE_ATTACHED FAKE_MOUNT_PATH
  rm -rf "$home" "$bin"
}

test_free_mount_point_skips_the_pre_flight() {
  local home bin calls rc=0 err="" warned=false mounted=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  add_fake_mount_table "$bin"
  calls="$home/calls"
  : >"$calls"
  export FAKE_ATTACHED="$home/attached" FAKE_MOUNT_PATH="$home/clouds/OneDrive"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  case "$err" in *"still attached"*) warned=true ;; esac
  if grep -Fq "mount OneDrive:Backups" "$calls"; then mounted=true; fi
  if [ "$warned" = false ] && [ "$mounted" = true ]; then
    assert_pass "a free mount point mounts without a pre-flight warning"
  else
    assert_fail "rclone-mount-no-stale-volume" \
      "rc=$rc warned=$warned mounted=$mounted stderr=[$err]"
  fi
  unset FAKE_ATTACHED FAKE_MOUNT_PATH
  rm -rf "$home" "$bin"
}

section "5" "wedged mount table"

# A wedged volume blocks mount(8) itself, so the probe is bounded and a probe that
# outlives its bound counts as attached. This case costs about 10 s: that bound is
# the behaviour under test.
test_hung_mount_probe_is_bounded_and_counts_as_attached() {
  local home bin calls errfile pid="" rc=0 warned=false mounted=false elapsed=0
  local started_at="$SECONDS"
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  add_fake_mount_table "$bin"
  calls="$home/calls"
  errfile="$home/err"
  : >"$calls"
  export FAKE_HANG_ONCE="$home/hang-once" FAKE_MOUNT_PATH="$home/clouds/OneDrive"
  run_mount_bg "$home" "$bin" "$calls" "$errfile"
  pid="$RUN_MOUNT_BG_PID"
  wait_bounded "$pid" 40 || rc=$?
  elapsed=$((SECONDS - started_at))
  case "$(cat "$errfile")" in *"a volume is still attached at '$home/clouds/OneDrive'"*) warned=true ;; esac
  if grep -Fq "mount OneDrive:Backups" "$calls"; then mounted=true; fi
  if [ "$rc" -ne 137 ] && [ "$warned" = true ] && [ "$mounted" = true ] && [ "$elapsed" -lt 30 ]; then
    assert_pass "a mount probe that never returns is bounded and treated as still attached"
  else
    assert_fail "rclone-mount-hung-probe" \
      "rc=$rc warned=$warned mounted=$mounted elapsed=${elapsed}s stderr=[$(cat "$errfile")]"
  fi
  unset FAKE_HANG_ONCE FAKE_MOUNT_PATH
  rm -rf "$home" "$bin"
}

section "6" "FSKit provider failure"

# WHY: a mount that writes nothing and never attaches is parked behind macFUSE's
# modal "unexpected error" dialog; the attempt bound is the only thing that ends
# it, and the failure has to be recorded and stopped, because every retry
# re-registers the extension and pushes the provider further out of FSKit's list.
test_parked_mount_is_bounded_and_recorded_as_a_provider_failure() {
  local home bin calls err="" rc=0 marker="" elapsed=0 recorded=false remedy=false mounted=false
  local started_at="$SECONDS"
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_parked)"
  calls="$home/calls"
  marker="$(blocked_marker "$home")"
  : >"$calls"
  export NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT=2
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  unset NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT
  elapsed=$((SECONDS - started_at))
  if grep -Fq "mount OneDrive:Backups" "$calls"; then mounted=true; fi
  case "$err" in *"provider refused the mount of"*) recorded=true ;; esac
  case "$err" in *"killall fskitd"*) remedy=true ;; esac
  if [ "$rc" -eq 0 ] && [ -e "$marker" ] && [ "$mounted" = true ] && [ "$elapsed" -lt 15 ] &&
    [ "$recorded" = true ] && [ "$remedy" = true ]; then
    assert_pass "a parked mount is bounded, recorded as a provider failure and stopped"
  else
    assert_fail "rclone-mount-parked-mount" \
      "rc=$rc marker=$([ -e "$marker" ] && echo yes || echo no) mounted=$mounted elapsed=${elapsed}s recorded=$recorded remedy=$remedy stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

# The same failure reported immediately: FSKit refuses the volume, rclone exits
# non-zero, and the wrapper must still stop instead of propagating a status that
# KeepAlive reloads into another refused attempt.
test_provider_refusal_is_recorded_and_stopped() {
  local home bin calls err="" rc=0 marker="" recorded=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_refused)"
  calls="$home/calls"
  marker="$(blocked_marker "$home")"
  : >"$calls"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 3 2>&1)" || rc=$?
  case "$err" in *"provider refused the mount of"*) recorded=true ;; esac
  if [ "$rc" -eq 0 ] && [ -e "$marker" ] && [ "$recorded" = true ]; then
    assert_pass "a provider refusal is recorded and stopped instead of retried"
  else
    assert_fail "rclone-mount-provider-refusal" \
      "rc=$rc marker=$([ -e "$marker" ] && echo yes || echo no) recorded=$recorded stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

# A volume that attaches proves the provider is serving again, so the record of an
# earlier failure must not outlive it: otherwise the status commands and the
# watchdog keep reporting a mount as blocked while it is up.
test_an_attached_volume_clears_the_blocked_marker() {
  local home bin calls err="" rc=0 marker="" cleared=false recorded=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_attached)"
  add_fake_mount_table "$bin"
  calls="$home/calls"
  marker="$(blocked_marker "$home")"
  : >"$calls"
  mkdir -p "$(dirname "$marker")"
  : >"$marker"
  export FAKE_ATTACHED="$home/attached" FAKE_MOUNT_PATH="$home/clouds/OneDrive"
  # The volume attaches while rclone is serving it, after the pre-flight probe has
  # already seen the path free.
  (
    sleep 1
    : >"$FAKE_ATTACHED"
  ) &
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  if [ ! -e "$marker" ]; then cleared=true; fi
  case "$err" in *"provider refused the mount of"*) recorded=true ;; esac
  if [ "$cleared" = true ] && [ "$recorded" = false ]; then
    assert_pass "a volume that attaches clears the blocked marker"
  else
    assert_fail "rclone-mount-attach-clears-marker" \
      "rc=$rc cleared=$cleared recorded=$recorded stderr=[$err]"
  fi
  unset FAKE_ATTACHED FAKE_MOUNT_PATH
  rm -rf "$home" "$bin"
}

# WHY: a volume destroyed seconds after it attaches leaves rclone exiting 0 — a
# status KeepAlive never retries — so the watcher has to notice the vanished volume
# and fail the mount, which is what reloads the path.
test_a_volume_that_vanishes_after_attaching_is_reported_and_failed() {
  local home bin calls err="" rc=0 vanished=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_attached)"
  add_fake_mount_table "$bin"
  calls="$home/calls"
  : >"$calls"
  export FAKE_ATTACHED="$home/attached" FAKE_MOUNT_PATH="$home/clouds/OneDrive"
  export NUCLEUS_CLOUD_MOUNT_DECAY_INTERVAL=1
  (
    sleep 1
    : >"$FAKE_ATTACHED"
    sleep 3
    rm -f "$FAKE_ATTACHED"
  ) &
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  unset NUCLEUS_CLOUD_MOUNT_DECAY_INTERVAL FAKE_ATTACHED FAKE_MOUNT_PATH
  case "$err" in *"disappeared"*) vanished=true ;; esac
  if [ "$rc" -eq 1 ] && [ "$vanished" = true ]; then
    assert_pass "a volume that vanishes after it attached fails the mount"
  else
    assert_fail "rclone-mount-decayed-volume" "rc=$rc vanished=$vanished stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

# add_disabled_fskit_probe <bin> <home> — make the FSKit probe answer 'disabled':
# a readable module list plus a plutil that reports no macFUSE module, so the probe
# branch of the classification can be exercised without a real FSKit.
add_disabled_fskit_probe() {
  local bin="$1" home="$2" plist_dir
  plist_dir="$home/Library/Group Containers/group.com.apple.fskit.settings"
  mkdir -p "$plist_dir"
  : >"$plist_dir/enabledModules.plist"
  cat >"$bin/plutil" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '"5" => "com.apple.other.fsmodule"'
STUB
  chmod +x "$bin/plutil"
}

# no_blocked_marker <home> — whether neither host's marker directory holds one.
# Returns 0 when the wrapper recorded nothing under either root.
no_blocked_marker() {
  if [ -e "$(blocked_marker "$1")" ] || [ -e "$(blocked_marker "$1" Linux)" ]; then
    return 1
  fi
  return 0
}

# WHY: FSKit does not exist off macOS, so the provider's own message is an
# ordinary mount failure there: it has to keep rclone's status so the supervisor
# reloads the mount, and it must write no marker whose remedy cannot run there.
test_provider_refusal_off_macos_is_not_recorded() {
  local home bin calls err="" rc=0 recorded=false markers=no
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_refused)"
  calls="$home/calls"
  : >"$calls"
  export FAKE_UNAME_S=Linux
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 3 2>&1)" || rc=$?
  unset FAKE_UNAME_S
  case "$err" in *"provider refused the mount of"*) recorded=true ;; esac
  if ! no_blocked_marker "$home"; then markers=yes; fi
  if [ "$rc" -eq 3 ] && [ "$markers" = no ] && [ "$recorded" = false ]; then
    assert_pass "a provider refusal off macOS keeps rclone's status and writes no marker"
  else
    assert_fail "rclone-mount-refusal-off-macos" \
      "rc=$rc markers=$markers recorded=$recorded stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

# WHY: off macOS only the bound applies to a mount that never attaches — the
# attempt is stopped and failed so the supervisor reloads it, because an operator
# has no macOS provider remedy to run on that host.
test_stalled_attempt_off_macos_is_reloaded_not_blocked() {
  local home bin calls err="" rc=0 markers=no reported=false remedy=false bounded=false
  local started_at="$SECONDS" elapsed=0
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone_parked)"
  calls="$home/calls"
  : >"$calls"
  export NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT=2
  export FAKE_UNAME_S=Linux
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 0 2>&1)" || rc=$?
  unset NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT FAKE_UNAME_S
  elapsed=$((SECONDS - started_at))
  case "$err" in *"no volume attached at"*) reported=true ;; esac
  case "$err" in *"killall fskitd"*) remedy=true ;; esac
  if ! no_blocked_marker "$home"; then markers=yes; fi
  if [ "$elapsed" -lt 15 ]; then bounded=true; fi
  if [ "$rc" -eq 1 ] && [ "$markers" = no ] && [ "$reported" = true ] && [ "$remedy" = false ] &&
    [ "$bounded" = true ]; then
    assert_pass "a stalled attempt off macOS is reported and reloaded instead of blocked"
  else
    assert_fail "rclone-mount-stall-off-macos" \
      "rc=$rc markers=$markers reported=$reported remedy=$remedy bounded=$bounded elapsed=${elapsed}s stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

# WHY: the probe is the other half of the classification and the decisive one when
# FSKit's module list is stale, so it must not fire off macOS even when a plutil on
# PATH answers 'disabled' for a mount that failed for its own reason.
test_a_disabled_probe_off_macos_does_not_block() {
  local home bin calls err="" rc=0 recorded=false markers=no
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  add_disabled_fskit_probe "$bin" "$home"
  calls="$home/calls"
  : >"$calls"
  export FAKE_UNAME_S=Linux
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 7 2>&1)" || rc=$?
  unset FAKE_UNAME_S
  case "$err" in *"provider refused the mount of"*) recorded=true ;; esac
  if ! no_blocked_marker "$home"; then markers=yes; fi
  if [ "$rc" -eq 7 ] && [ "$markers" = no ] && [ "$recorded" = false ]; then
    assert_pass "a disabled FSKit probe off macOS neither blocks nor records the mount"
  else
    assert_fail "rclone-mount-disabled-probe-off-macos" \
      "rc=$rc markers=$markers recorded=$recorded stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

# The macOS counterpart of the previous test, so the gate is what changed and not
# the classification: the same disabled probe must still stop the mount there.
test_a_disabled_probe_on_macos_blocks_the_mount() {
  local home bin calls err="" rc=0 markers=no recorded=false remedy=false
  home="$(mktemp -d)"
  bin="$(setup_fake_rclone)"
  add_disabled_fskit_probe "$bin" "$home"
  calls="$home/calls"
  : >"$calls"
  err="$(run_mount "$home" "$bin" "$calls" "OneDrive:" 7 2>&1)" || rc=$?
  case "$err" in *"provider refused the mount of"*) recorded=true ;; esac
  case "$err" in *"killall fskitd"*) remedy=true ;; esac
  if ! no_blocked_marker "$home"; then markers=yes; fi
  if [ "$rc" -eq 0 ] && [ "$markers" = yes ] && [ "$recorded" = true ] && [ "$remedy" = true ]; then
    assert_pass "a disabled FSKit probe on macOS blocks the mount and records the remedy"
  else
    assert_fail "rclone-mount-disabled-probe-on-macos" \
      "rc=$rc markers=$markers recorded=$recorded remedy=$remedy stderr=[$err]"
  fi
  rm -rf "$home" "$bin"
}

test_failed_mount_exit_is_reported_and_propagated
test_clean_mount_exit_is_still_reported
test_remote_and_mount_point_reach_rclone
test_unconfigured_remote_skips_without_a_restart_loop
test_failing_remote_listing_fails_the_wrapper
test_stop_request_waits_for_rclone_to_finish
test_slow_stop_is_waited_out_and_reported
test_mount_killed_while_stopping_does_not_spin_the_wrapper
test_attached_volume_is_released_before_mounting
test_unreleasable_volume_refuses_the_mount
test_free_mount_point_skips_the_pre_flight
test_hung_mount_probe_is_bounded_and_counts_as_attached
test_parked_mount_is_bounded_and_recorded_as_a_provider_failure
test_provider_refusal_is_recorded_and_stopped
test_an_attached_volume_clears_the_blocked_marker
test_a_volume_that_vanishes_after_attaching_is_reported_and_failed
test_provider_refusal_off_macos_is_not_recorded
test_stalled_attempt_off_macos_is_reloaded_not_blocked
test_a_disabled_probe_off_macos_does_not_block
test_a_disabled_probe_on_macos_blocks_the_mount
finish_tests
