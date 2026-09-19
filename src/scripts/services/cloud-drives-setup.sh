#!/usr/bin/env bash
# Cloud drive directory structure setup: mount points (a real directory on every
# host, macOS included) and replica directories.  A mount that the previous
# attempt left blocked is reported with its recorded remedy, so a missing drive
# is never silent.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/crash-loop.sh
. "$SCRIPT_DIR/../lib/crash-loop.sh"
# shellcheck source=../lib/svc-instances.sh
. "$SCRIPT_DIR/../lib/svc-instances.sh"

# Ensure a managed real directory exists at PATH.
# Usage: _cd_ensure_real_directory "$HOME/path/to/mountpoint" "mount display name" "local.cloud-mount.gdrive"
# SERVICE_LABEL names the macOS LaunchAgent that owns a mount at this path; it is
# quoted in the remedy when the path is a symlink, and may be empty.
_cd_ensure_real_directory() {
  _cd_path="$1"
  _cd_name="$2"
  _cd_service_label="${3-}"

  if [ -L "$_cd_path" ]; then
    # WHY: a symlink here is either the leftover of the retired /Volumes mount
    #   layout — whose mount point never came into existence, so the link dangles
    #   — or a user-placed link.  The link carries no data, but a mount attached
    #   through it does, so the agent that owns it is named before the removal.
    #   The literal $(id -u) is for the operator to paste, not to expand.
    _cd_remedy="fix manually and re-apply"
    if [ -n "$_cd_service_label" ]; then
      _cd_remedy="if a cloud drive mount is still attached there, unload its agent with launchctl bootout \"gui/\$(id -u)/$_cd_service_label\", then remove the symlink with rm \"$_cd_path\" and re-apply"
    fi
    printf '%s\n' "cloud-drives (${_cd_name}): error: $_cd_path is a symlink to $(readlink "$_cd_path"); $_cd_remedy" >&2
    exit 1
  fi
  if [ -e "$_cd_path" ] && [ ! -d "$_cd_path" ]; then
    printf '%s\n' "cloud-drives (${_cd_name}): error: $_cd_path exists and is not a directory; fix manually and re-apply" >&2
    exit 1
  fi
  # WHY: a mounted cloud drive makes this path look occupied, and re-applying must
  #   stay idempotent, so occupancy is not rejected here — rclone owns that check
  #   and refuses a non-empty mount point with its own message.
  mkdir -p "$_cd_path"
}

_vsd_jq_bin="$1"
_vsd_mounts_json="$2"
_vsd_replicas_json="$3"

# Create the top-level clouds/ directory tree.
mkdir -p "$HOME/clouds"

# Process mounts: the mount point is a real directory on every host, macOS
# included — rclone stats the mount point before mounting, so macFUSE never gets
# the chance to create one under /Volumes.
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_local_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.localPath')"
  _vsd_service_label="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.serviceLabel // empty')"
  _cd_ensure_real_directory "$HOME/$_vsd_local_path" "$_vsd_local_path" "$_vsd_service_label"

  # WHY a warning, not an error: only a provider repair brings the volume back,
  #   and the mount records that itself once it attaches — failing the apply here
  #   would block the convergence of everything else for a state it cannot fix.
  #   The marker is boot-scoped, so a reboot (the standing remedy) clears it.
  if [ -n "$_vsd_service_label" ]; then
    _vsd_blocked="$(svc_blocked_state "$_vsd_service_label" "$(crash_loop_state_dir)")"
    if [ "$_vsd_blocked" != "clear" ]; then
      printf '%s\n' "cloud-drives ($_vsd_local_path): warning: the last mount attempt was blocked ($_vsd_blocked); $(svc_blocked_remedy "$_vsd_service_label" "$(crash_loop_state_dir)")" >&2
    fi
  fi
done < <(printf '%s\n' "$_vsd_mounts_json" | "$_vsd_jq_bin" -r -c '.[]')

# Process replicas: ensure each replica directory or symlink exists.
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_local_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.localPath')"
  _vsd_display_name="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.name')"
  _vsd_is_special_icloud="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.isSpecialICloud')"

  if [ "$_vsd_is_special_icloud" = "true" ]; then
    # macOS-only exception: iCloudReplica must point to native CloudDocs
    # storage so we do not duplicate Apple's iCloud integration with a
    # second managed tree.  Only reachable on Darwin (the isSpecialICloud
    # flag is set at Nix eval time based on pkgs.stdenv.hostPlatform.isDarwin).
    _vsd_icloud_native_target="$HOME/Library/Mobile Documents"
    _vsd_icloud_replica_path="$HOME/$_vsd_local_path"

    if [ -L "$_vsd_icloud_replica_path" ]; then
      if [ "$(readlink "$_vsd_icloud_replica_path")" != "$_vsd_icloud_native_target" ]; then
        printf '%s\n' "cloud-drives ($_vsd_display_name): error: $_vsd_icloud_replica_path must symlink to $_vsd_icloud_native_target; fix manually and re-apply" >&2
        exit 1
      fi
    elif [ -e "$_vsd_icloud_replica_path" ]; then
      printf '%s\n' "cloud-drives ($_vsd_display_name): error: $_vsd_icloud_replica_path exists and is not the native iCloud symlink; fix manually and re-apply" >&2
      exit 1
    else
      ln -s "$_vsd_icloud_native_target" "$_vsd_icloud_replica_path"
      printf '%s\n' "cloud-drives ($_vsd_display_name): linked $_vsd_icloud_replica_path -> $_vsd_icloud_native_target (native iCloud replica path)."
    fi
  else
    _cd_ensure_real_directory "$HOME/$_vsd_local_path" "$_vsd_display_name"
  fi
done < <(printf '%s\n' "$_vsd_replicas_json" | "$_vsd_jq_bin" -r -c '.[]')
