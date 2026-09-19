#!/usr/bin/env bash
# cloud-drives-setup.sh — mount-path convergence and replica directories.
#
# Every host mounts rclone drives at clouds/<id>, a real directory — macOS
# included, because rclone stats the mount point before mounting and macFUSE only
# creates a /Volumes mount point while mounting a volume. The regressions this
# guards: treating the mount path as a symlink again, and a re-apply that fails
# or destroys state it must leave alone — a mounted drive makes its mount point
# look occupied, and the leftover symlink of the retired /Volumes layout must
# fail loudly with a paste-ready remedy instead of being followed or deleted.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/svc-instances.sh
. "$SCRIPT_DIR/../../src/scripts/lib/svc-instances.sh"
# shellcheck source=../../src/scripts/lib/macos-fskit.sh
. "$SCRIPT_DIR/../../src/scripts/lib/macos-fskit.sh"

CD_SETUP_SH="$SCRIPT_DIR/../../src/scripts/services/cloud-drives-setup.sh"

require_command jq "cloud-drives-setup.sh parses its mount and replica arguments with jq"
JQ_BIN="$(command -v jq)"

run_setup() { # <home> <mounts_json> <replicas_json>
  HOME="$1" bash "$CD_SETUP_SH" "$JQ_BIN" "$2" "$3"
}

# Same invocation with the progress output discarded, so the caller can capture
# the error line with `2>&1`.
run_setup_stderr() { # <home> <mounts_json> <replicas_json>
  HOME="$1" bash "$CD_SETUP_SH" "$JQ_BIN" "$2" "$3" 1>/dev/null
}

_mounts_plain='[{"localPath":"clouds/GoogleDrive"}]'
_mounts_labeled='[{"localPath":"clouds/GoogleDrive","serviceLabel":"local.cloud-mount.GoogleDrive"}]'
_replicas_none='[]'

section "1" "mount paths"

test_mount_path_is_a_real_directory() {
  local home rc=0
  home="$(mktemp -d)"
  run_setup "$home" "$_mounts_plain" "$_replicas_none" || rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$home/clouds/GoogleDrive" ] && [ ! -L "$home/clouds/GoogleDrive" ]; then
    assert_pass "a mount path is created as a real directory"
  else
    assert_fail "cloud-drives-mount-dir" \
      "rc=$rc isdir=$([ -d "$home/clouds/GoogleDrive" ] && echo yes || echo no)"
  fi
  rm -rf "$home"
}

test_mount_path_is_idempotent() {
  local home rc=0
  home="$(mktemp -d)"
  run_setup "$home" "$_mounts_plain" "$_replicas_none" || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_fail "cloud-drives-mount-idempotent" "first run rc=$rc"
  elif run_setup "$home" "$_mounts_plain" "$_replicas_none" &&
    [ -d "$home/clouds/GoogleDrive" ] && [ ! -L "$home/clouds/GoogleDrive" ]; then
    assert_pass "re-applying keeps the mount path a real directory"
  else
    assert_fail "cloud-drives-mount-idempotent" "second run rc=$?"
  fi
  rm -rf "$home"
}

test_mount_path_tolerates_an_occupied_directory() {
  local home rc=0
  home="$(mktemp -d)"
  # A mounted drive makes its mount point look occupied, so occupancy must not
  # fail the apply: rclone owns the non-empty check and it is the only failure
  # that can clear itself once the mount is gone.
  mkdir -p "$home/clouds/GoogleDrive"
  printf 'mounted contents\n' >"$home/clouds/GoogleDrive/remote-file"
  run_setup "$home" "$_mounts_plain" "$_replicas_none" || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$home/clouds/GoogleDrive/remote-file" ]; then
    assert_pass "an occupied mount path is left to rclone's non-empty check"
  else
    assert_fail "cloud-drives-mount-occupied" "rc=$rc"
  fi
  rm -rf "$home"
}

test_mount_path_symlink_error_names_how_to_release_it() {
  local home rc=0 err="" agent_ok=false remove_ok=false target_ok=false expected_agent expected_remove
  home="$(mktemp -d)"
  # Both parts of the remedy must be paste-ready and name this fixture's own
  # path, not a placeholder: bootout releases a volume the retired layout's
  # agent still owns, and only the operator may delete the leftover link.
  expected_agent="launchctl bootout \"gui/\$(id -u)/local.cloud-mount.GoogleDrive\""
  expected_remove="rm \"$home/clouds/GoogleDrive\""
  mkdir -p "$home/clouds"
  ln -s "/Volumes/nucleus-cloud-GoogleDrive" "$home/clouds/GoogleDrive"
  err="$(run_setup_stderr "$home" "$_mounts_labeled" "$_replicas_none" 2>&1)" || rc=$?
  case "$err" in *"$expected_agent"*) agent_ok=true ;; esac
  case "$err" in *"$expected_remove"*) remove_ok=true ;; esac
  case "$err" in *"/Volumes/nucleus-cloud-GoogleDrive"*) target_ok=true ;; esac
  if [ "$rc" -ne 0 ] && [ -L "$home/clouds/GoogleDrive" ] &&
    [ "$agent_ok" = true ] && [ "$remove_ok" = true ] && [ "$target_ok" = true ]; then
    assert_pass "a leftover mount symlink names its target, its agent, and the removal"
  else
    assert_fail "cloud-drives-mount-symlink-remedy" \
      "rc=$rc agent=$agent_ok remove=$remove_ok target=$target_ok stderr=[$err]"
  fi
  rm -rf "$home"
}

test_mount_path_symlink_error_without_a_label_stays_generic() {
  local home rc=0 err="" generic_ok=false remedy_absent=false
  home="$(mktemp -d)"
  mkdir -p "$home/clouds"
  ln -s "$home/elsewhere" "$home/clouds/GoogleDrive"
  err="$(run_setup_stderr "$home" "$_mounts_plain" "$_replicas_none" 2>&1)" || rc=$?
  case "$err" in *'fix manually and re-apply'*) generic_ok=true ;; esac
  case "$err" in
  *launchctl*) remedy_absent=false ;;
  *) remedy_absent=true ;;
  esac
  if [ "$rc" -ne 0 ] && [ -L "$home/clouds/GoogleDrive" ] &&
    [ "$generic_ok" = true ] && [ "$remedy_absent" = true ]; then
    assert_pass "a symlinked mount path without an agent label keeps the generic message"
  else
    assert_fail "cloud-drives-mount-symlink-no-label" \
      "rc=$rc generic=$generic_ok remedy_absent=$remedy_absent stderr=[$err]"
  fi
  rm -rf "$home"
}

# mark_blocked <home> <service label> — a fresh blocked marker, as the mount
# wrapper leaves it when the FSKit provider refuses the volume.
mark_blocked() { # <home> <label>
  local state_dir="$1/Library/Application Support/nucleus/state/service-stats"
  svc_blocked_set "$2" "$state_dir" fskit-provider "$(fskit_remedy)"
}

test_blocked_mount_warns_with_its_remedy() {
  local home rc=0 err="" reported=false remedy_ok=false
  home="$(mktemp -d)"
  mark_blocked "$home" local.cloud-mount.GoogleDrive
  err="$(run_setup_stderr "$home" "$_mounts_labeled" "$_replicas_none" 2>&1)" || rc=$?
  case "$err" in *'cloud-drives (clouds/GoogleDrive): warning'*) reported=true ;; esac
  case "$err" in *'nucleus-cloud repair'*) remedy_ok=true ;; esac
  if [ "$rc" -eq 0 ] && [ "$reported" = true ] && [ "$remedy_ok" = true ]; then
    assert_pass "a blocked mount is reported with the remedy, and the apply still succeeds"
  else
    assert_fail "cloud-drives-blocked-mount-warning" \
      "rc=$rc reported=$reported remedy=$remedy_ok stderr=[$err]"
  fi
  rm -rf "$home"
}

test_unblocked_mount_is_silent() {
  local home rc=0 err="" quiet=true
  home="$(mktemp -d)"
  err="$(run_setup_stderr "$home" "$_mounts_labeled" "$_replicas_none" 2>&1)" || rc=$?
  case "$err" in *warning*) quiet=false ;; esac
  if [ "$rc" -eq 0 ] && [ "$quiet" = true ]; then
    assert_pass "a mount without a blocked marker is not reported"
  else
    assert_fail "cloud-drives-unblocked-mount-quiet" "rc=$rc stderr=[$err]"
  fi
  rm -rf "$home"
}

# WHY: the marker is boot-scoped, so one written before a reboot (the standing
# remedy) must not be reported as a current problem.
test_stale_blocked_mount_is_silent() {
  local home rc=0 err="" quiet=true state_dir file
  home="$(mktemp -d)"
  state_dir="$home/Library/Application Support/nucleus/state/service-stats"
  mkdir -p "$state_dir"
  file="$state_dir/local.cloud-mount.GoogleDrive.blocked"
  printf 'class=fskit-provider\nboot=other-boot\nts=1\n' >"$file"
  err="$(run_setup_stderr "$home" "$_mounts_labeled" "$_replicas_none" 2>&1)" || rc=$?
  case "$err" in *warning*) quiet=false ;; esac
  if [ "$rc" -eq 0 ] && [ "$quiet" = true ]; then
    assert_pass "a blocked marker from an earlier boot is not reported"
  else
    assert_fail "cloud-drives-stale-blocked-mount-quiet" "rc=$rc stderr=[$err]"
  fi
  rm -rf "$home"
}

section "2" "replica directories"

test_replica_directory_is_a_real_directory() {
  local home rc=0
  home="$(mktemp -d)"
  run_setup "$home" '[]' \
    '[{"localPath":"clouds/OneDriveReplica","name":"OneDrive replica","isSpecialICloud":false}]' ||
    rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$home/clouds/OneDriveReplica" ] &&
    [ ! -L "$home/clouds/OneDriveReplica" ]; then
    assert_pass "a replica path is created as a real directory"
  else
    assert_fail "cloud-drives-replica-dir" "rc=$rc"
  fi
  rm -rf "$home"
}

test_icloud_replica_links_to_native_storage() {
  local home rc=0
  home="$(mktemp -d)"
  run_setup "$home" '[]' \
    '[{"localPath":"clouds/iCloudReplica","name":"iCloud","isSpecialICloud":true}]' || rc=$?
  if [ "$rc" -eq 0 ] && [ -L "$home/clouds/iCloudReplica" ] &&
    [ "$(readlink "$home/clouds/iCloudReplica")" = "$home/Library/Mobile Documents" ]; then
    assert_pass "the macOS iCloud replica links to the native CloudDocs area"
  else
    assert_fail "cloud-drives-icloud-replica" \
      "rc=$rc link=$(readlink "$home/clouds/iCloudReplica" 2>/dev/null)"
  fi
  rm -rf "$home"
}

test_mount_path_is_a_real_directory
test_mount_path_is_idempotent
test_mount_path_tolerates_an_occupied_directory
test_mount_path_symlink_error_names_how_to_release_it
test_mount_path_symlink_error_without_a_label_stays_generic
test_blocked_mount_warns_with_its_remedy
test_unblocked_mount_is_silent
test_stale_blocked_mount_is_silent
test_replica_directory_is_a_real_directory
test_icloud_replica_links_to_native_storage
finish_tests
