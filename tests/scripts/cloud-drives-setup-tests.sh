#!/usr/bin/env bash
# cloud-drives-setup.sh — mount-path convergence and replica directories.
#
# macOS FSKit volumes are mounted at a direct child of /Volumes, so clouds/<id>
# is a symlink to that mount point; on every other host clouds/<id> *is* the
# mount point. The regression this guards: treating the macOS path as a real
# directory (rclone then refuses to mount, or mounts into a directory the user
# cannot see), and any state conflict being papered over instead of failing.
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

_mounts_macos='[{"localPath":"clouds/GoogleDrive","mountPoint":"/Volumes/nucleus-cloud-GoogleDrive"}]'
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

test_macos_mount_path_rejects_foreign_symlink() {
  local home rc=0
  home="$(mktemp -d)"
  mkdir -p "$home/clouds"
  ln -s "/Volumes/somewhere-else" "$home/clouds/GoogleDrive"
  run_setup "$home" "$_mounts_macos" "$_replicas_none" || rc=$?
  if [ "$rc" -ne 0 ] &&
    [ "$(readlink "$home/clouds/GoogleDrive")" = "/Volumes/somewhere-else" ]; then
    assert_pass "a macOS mount path pointing elsewhere fails instead of being rewritten"
  else
    assert_fail "cloud-drives-macos-mount-foreign-link" \
      "rc=$rc link=$(readlink "$home/clouds/GoogleDrive" 2>/dev/null)"
  fi
  rm -rf "$home"
}

test_macos_mount_path_rejects_real_directory() {
  local home rc=0
  home="$(mktemp -d)"
  mkdir -p "$home/clouds/GoogleDrive"
  printf 'user data\n' >"$home/clouds/GoogleDrive/keep.txt"
  run_setup "$home" "$_mounts_macos" "$_replicas_none" || rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$home/clouds/GoogleDrive/keep.txt" ] &&
    [ ! -L "$home/clouds/GoogleDrive" ]; then
    assert_pass "an existing real directory is left intact and fails loudly"
  else
    assert_fail "cloud-drives-macos-mount-real-dir" "rc=$rc"
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
test_macos_mount_path_rejects_foreign_symlink
test_macos_mount_path_rejects_real_directory
test_local_mount_path_is_real_directory
test_local_mount_path_rejects_symlink
test_replica_directory_is_a_real_directory
test_icloud_replica_links_to_native_storage
finish_tests
