#!/usr/bin/env bash
# rclone-mount.sh — the mount wrapper's exit report and remote guard.
#
# rclone runs with --log-level ERROR and the LaunchAgent sets
# KeepAlive{SuccessfulExit = false}, so a mount that exits cleanly writes nothing
# and is never retried: the job can be down while its log looks healthy. The
# regressions this guards: that exit going unreported, the report losing rclone's
# status or the mount point, and the deliberate skip of an unconfigured remote
# turning into a crash loop instead of a clean exit.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
MOUNT_SH="$REPO_ROOT/src/scripts/services/rclone-mount.sh"

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
    bash "$MOUNT_SH" 1>/dev/null
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
  if [ "$rc" -eq 0 ] && [ "$reported" = true ]; then
    assert_pass "a clean exit that leaves no mount is reported instead of passing silently"
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
  if [ "$rc" -eq 0 ] && [ "$forwarded" = true ]; then
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

test_failed_mount_exit_is_reported_and_propagated
test_clean_mount_exit_is_still_reported
test_remote_and_mount_point_reach_rclone
test_unconfigured_remote_skips_without_a_restart_loop
test_failing_remote_listing_fails_the_wrapper
finish_tests
