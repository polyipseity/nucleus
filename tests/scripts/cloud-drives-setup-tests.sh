#!/usr/bin/env bash
# cloud-drives-setup.sh — mount-path convergence and replica directories.
#
# macOS FSKit volumes are mounted at a direct child of /Volumes, so clouds/<id>
# is a symlink to that mount point; on every other host clouds/<id> *is* the
# mount point. The regression this guards: treating the macOS path as a real
# directory (rclone then refuses to mount, or mounts into a directory the user
# cannot see), and any state conflict being papered over instead of failing,
# except the two cases the migration converges: a stale symlink target and a
# leftover empty directory.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

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

_mounts_macos='[{"localPath":"clouds/GoogleDrive","mountPoint":"/Volumes/nucleus-cloud-GoogleDrive"}]'
_mounts_macos_labeled='[{"localPath":"clouds/GoogleDrive","mountPoint":"/Volumes/nucleus-cloud-GoogleDrive","serviceLabel":"local.cloud-mount.GoogleDrive"}]'
_replicas_none='[]'

section "1" "macOS mount paths"

test_macos_mount_path_becomes_symlink() {
  local home rc=0
  home="$(mktemp -d)"
  run_setup "$home" "$_mounts_macos" "$_replicas_none" || rc=$?
  if [ "$rc" -eq 0 ] && [ -L "$home/clouds/GoogleDrive" ] &&
    [ "$(readlink "$home/clouds/GoogleDrive")" = "/Volumes/nucleus-cloud-GoogleDrive" ]; then
    assert_pass "a macOS mount path becomes a symlink to the /Volumes mount point"
  else
    assert_fail "cloud-drives-macos-mount-link" \
      "rc=$rc link=$(readlink "$home/clouds/GoogleDrive" 2>/dev/null)"
  fi
  rm -rf "$home"
}

test_macos_mount_path_is_idempotent() {
  local home rc=0
  home="$(mktemp -d)"
  run_setup "$home" "$_mounts_macos" "$_replicas_none" || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_fail "cloud-drives-macos-mount-idempotent" "first run rc=$rc"
  elif run_setup "$home" "$_mounts_macos" "$_replicas_none" &&
    [ "$(readlink "$home/clouds/GoogleDrive")" = "/Volumes/nucleus-cloud-GoogleDrive" ]; then
    assert_pass "re-applying keeps the macOS mount symlink unchanged"
  else
    assert_fail "cloud-drives-macos-mount-idempotent" \
      "second run rc=$? link=$(readlink "$home/clouds/GoogleDrive" 2>/dev/null)"
  fi
  rm -rf "$home"
}

test_macos_mount_path_repairs_foreign_symlink() {
  local home rc=0
  home="$(mktemp -d)"
  mkdir -p "$home/clouds"
  ln -s "/Volumes/somewhere-else" "$home/clouds/GoogleDrive"
  run_setup "$home" "$_mounts_macos" "$_replicas_none" || rc=$?
  if [ "$rc" -eq 0 ] &&
    [ "$(readlink "$home/clouds/GoogleDrive")" = "/Volumes/nucleus-cloud-GoogleDrive" ]; then
    assert_pass "a stale symlink target is relinked to the configured macOS mount point"
  else
    assert_fail "cloud-drives-macos-mount-foreign-link" \
      "rc=$rc link=$(readlink "$home/clouds/GoogleDrive" 2>/dev/null)"
  fi
  rm -rf "$home"
}

test_macos_mount_path_replaces_empty_directory() {
  local home rc=0
  home="$(mktemp -d)"
  mkdir -p "$home/clouds/GoogleDrive"
  run_setup "$home" "$_mounts_macos" "$_replicas_none" || rc=$?
  if [ "$rc" -eq 0 ] && [ -L "$home/clouds/GoogleDrive" ] &&
    [ "$(readlink "$home/clouds/GoogleDrive")" = "/Volumes/nucleus-cloud-GoogleDrive" ]; then
    assert_pass "a leftover empty mount directory is replaced by the symlink"
  else
    assert_fail "cloud-drives-macos-mount-empty-dir" "rc=$rc"
  fi
  rm -rf "$home"
}

test_macos_mount_path_rejects_nonempty_directory() {
  local home rc=0
  home="$(mktemp -d)"
  mkdir -p "$home/clouds/GoogleDrive"
  printf 'user data\n' >"$home/clouds/GoogleDrive/keep.txt"
  run_setup "$home" "$_mounts_macos" "$_replicas_none" || rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$home/clouds/GoogleDrive/keep.txt" ] &&
    [ ! -L "$home/clouds/GoogleDrive" ]; then
    assert_pass "a non-empty real directory is left intact and fails loudly"
  else
    assert_fail "cloud-drives-macos-mount-real-dir" "rc=$rc"
  fi
  rm -rf "$home"
}

test_macos_mount_path_error_names_how_to_release_it() {
  local home rc=0 err="" agent_ok=false unmount_ok=false expected_agent expected_unmount
  home="$(mktemp -d)"
  # Both commands must be paste-ready and name this fixture's own occupied path,
  # not a placeholder: bootout releases a volume the old agent still owns, while
  # diskutil is the only escape for one that outlived an agent refresh.
  expected_agent="launchctl bootout \"gui/\$(id -u)/local.cloud-mount.GoogleDrive\""
  expected_unmount="diskutil unmount force \"$home/clouds/GoogleDrive\""
  mkdir -p "$home/clouds/GoogleDrive"
  printf 'user data\n' >"$home/clouds/GoogleDrive/keep.txt"
  err="$(run_setup_stderr "$home" "$_mounts_macos_labeled" "$_replicas_none" 2>&1)" || rc=$?
  case "$err" in
  *"$expected_agent"*) agent_ok=true ;;
  esac
  case "$err" in
  *"$expected_unmount"*) unmount_ok=true ;;
  esac
  if [ "$rc" -ne 0 ] && [ -f "$home/clouds/GoogleDrive/keep.txt" ] &&
    [ "$agent_ok" = true ] && [ "$unmount_ok" = true ]; then
    assert_pass "a blocked mount path names the LaunchAgent and the unmount command that release it"
  else
    assert_fail "cloud-drives-macos-mount-remedy" \
      "rc=$rc agent=$agent_ok unmount=$unmount_ok stderr=[$err]"
  fi
  rm -rf "$home"
}

test_macos_mount_path_error_without_a_label_stays_generic() {
  local home rc=0 err="" generic_ok=false remedy_absent=false
  home="$(mktemp -d)"
  mkdir -p "$home/clouds/GoogleDrive"
  printf 'user data\n' >"$home/clouds/GoogleDrive/keep.txt"
  err="$(run_setup_stderr "$home" "$_mounts_macos" "$_replicas_none" 2>&1)" || rc=$?
  case "$err" in *'fix manually and re-apply'*) generic_ok=true ;; esac
  case "$err" in
  *launchctl* | *diskutil*) remedy_absent=false ;;
  *) remedy_absent=true ;;
  esac
  if [ "$rc" -ne 0 ] && [ "$generic_ok" = true ] && [ "$remedy_absent" = true ]; then
    assert_pass "a blocked mount path without an agent label keeps the generic message"
  else
    assert_fail "cloud-drives-macos-mount-no-label" \
      "rc=$rc generic=$generic_ok remedy_absent=$remedy_absent stderr=[$err]"
  fi
  rm -rf "$home"
}

section "2" "non-macOS mount paths"

test_local_mount_path_is_real_directory() {
  local home rc=0
  home="$(mktemp -d)"
  run_setup "$home" "[{\"localPath\":\"clouds/OneDrive\",\"mountPoint\":\"$home/clouds/OneDrive\"}]" \
    "$_replicas_none" || rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$home/clouds/OneDrive" ] && [ ! -L "$home/clouds/OneDrive" ]; then
    assert_pass "a mount whose path is the mount point stays a real directory"
  else
    assert_fail "cloud-drives-local-mount-dir" \
      "rc=$rc isdir=$([ -d "$home/clouds/OneDrive" ] && echo yes || echo no)"
  fi
  rm -rf "$home"
}

test_local_mount_path_rejects_symlink() {
  local home rc=0
  home="$(mktemp -d)"
  mkdir -p "$home/clouds"
  ln -s "$home/elsewhere" "$home/clouds/OneDrive"
  run_setup "$home" "[{\"localPath\":\"clouds/OneDrive\",\"mountPoint\":\"$home/clouds/OneDrive\"}]" \
    "$_replicas_none" || rc=$?
  if [ "$rc" -ne 0 ] && [ -L "$home/clouds/OneDrive" ]; then
    assert_pass "a symlinked mount path is reported instead of being replaced"
  else
    assert_fail "cloud-drives-local-mount-symlink" "rc=$rc"
  fi
  rm -rf "$home"
}

section "3" "replica directories"

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

test_macos_mount_path_becomes_symlink
test_macos_mount_path_is_idempotent
test_macos_mount_path_repairs_foreign_symlink
test_macos_mount_path_replaces_empty_directory
test_macos_mount_path_rejects_nonempty_directory
test_macos_mount_path_error_names_how_to_release_it
test_macos_mount_path_error_without_a_label_stays_generic
test_local_mount_path_is_real_directory
test_local_mount_path_rejects_symlink
test_replica_directory_is_a_real_directory
test_icloud_replica_links_to_native_storage
finish_tests
