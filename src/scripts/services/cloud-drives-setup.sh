#!/usr/bin/env bash
# Cloud drive directory structure setup: mount paths (the FSKit mount point on
# macOS, a real directory elsewhere) and replica directories.
set -eu

# Ensure a managed real directory exists at PATH.
# Usage: _cd_ensure_real_directory "$HOME/path/to/mountpoint" "mount display name"
_cd_ensure_real_directory() {
  _cd_path="$1"
  _cd_name="$2"

  if [ -L "$_cd_path" ]; then
    printf '%s\n' "cloud-drives (${_cd_name}): error: $_cd_path is a symlink; fix manually and re-apply" >&2
    exit 1
  fi
  if [ -e "$_cd_path" ] && [ ! -d "$_cd_path" ]; then
    printf '%s\n' "cloud-drives (${_cd_name}): error: $_cd_path exists and is not a directory; fix manually and re-apply" >&2
    exit 1
  fi
  mkdir -p "$_cd_path"
}

# Ensure PATH is a symlink to TARGET, converging stale state at this config-owned
# path: a symlink carries no data, so a wrong target is relinked, and the mount
# path may legitimately be a leftover empty directory from an earlier layout.
# Usage: _cd_ensure_symlink "$HOME/clouds/gdrive" "/Volumes/nucleus-cloud-gdrive" "gdrive" "local.cloud-mount.gdrive"
# SERVICE_LABEL is the macOS LaunchAgent that owns the mount at this path; it is
# named in the remedy when the path is occupied, and may be empty.
_cd_ensure_symlink() {
  _cd_link="$1"
  _cd_target="$2"
  _cd_name="$3"
  _cd_service_label="$4"

  if [ -L "$_cd_link" ]; then
    if [ "$(readlink "$_cd_link")" = "$_cd_target" ]; then
      return 0
    fi
    rm "$_cd_link"
    ln -s "$_cd_target" "$_cd_link"
    printf '%s\n' "cloud-drives (${_cd_name}): relinked $_cd_link -> $_cd_target"
    return 0
  fi
  if [ -e "$_cd_link" ]; then
    if [ ! -d "$_cd_link" ] || [ -n "$(ls -A "$_cd_link")" ]; then
      _cd_remedy="fix manually and re-apply"
      if [ -n "$_cd_service_label" ]; then
        # WHY: this is what a mount left attached by the previous layout looks
        #   like from here, and "fix manually" alone gave no clue what to do.
        #   Both escapes are needed: bootout releases a volume the old agent
        #   still owns, while a volume that outlived an agent refresh can only
        #   be released by unmounting it — the refreshed agent mounts the
        #   /Volumes path, so booting it out frees nothing here.  The literal
        #   $(id -u) is for the operator to paste, not to expand.
        _cd_remedy="if a cloud drive mount is still attached there, unload its agent with launchctl bootout \"gui/\$(id -u)/$_cd_service_label\" or unmount it with diskutil unmount force \"$_cd_link\", or move the data aside; then re-apply"
      fi
      printf '%s\n' "cloud-drives (${_cd_name}): error: $_cd_link exists and is neither empty nor a symlink to $_cd_target; $_cd_remedy" >&2
      exit 1
    fi
    # WHY: rmdir rather than rm -rf — it refuses a mount point that is still
    #   attached, so a live mount can never be deleted from under the user.
    if ! rmdir "$_cd_link"; then
      printf '%s\n' "cloud-drives (${_cd_name}): error: cannot remove $_cd_link (still mounted?); unmount it and re-apply" >&2
      exit 1
    fi
    printf '%s\n' "cloud-drives (${_cd_name}): replaced empty directory with a symlink to $_cd_target"
  fi
  ln -s "$_cd_target" "$_cd_link"
  printf '%s\n' "cloud-drives (${_cd_name}): linked $_cd_link -> $_cd_target"
}

_vsd_jq_bin="$1"
_vsd_mounts_json="$2"
_vsd_replicas_json="$3"

# Create the top-level clouds/ directory tree.
mkdir -p "$HOME/clouds"

# Process mounts: converge the user-visible path.  macOS mounts under /Volumes,
# so clouds/<id> is a symlink to the mount point there; the mount point itself is
# created by macFUSE during the first mount, and creating it here would leave it
# owned by root.  Everywhere else the user-visible path is the mount point.
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_local_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.localPath')"
  _vsd_mount_point="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.mountPoint')"
  _vsd_service_label="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.serviceLabel // empty')"
  if [ "$_vsd_mount_point" = "$HOME/$_vsd_local_path" ]; then
    _cd_ensure_real_directory "$HOME/$_vsd_local_path" "$_vsd_local_path"
  else
    _cd_ensure_symlink "$HOME/$_vsd_local_path" "$_vsd_mount_point" "$_vsd_local_path" "$_vsd_service_label"
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
