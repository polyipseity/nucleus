# Cloud drive directory structure setup.
# Tokens (described below) are substituted at build time by Nix.
# Expects set -eu to be sourced before this script runs.
set -eu

# Source library helpers
__CLOUD_DRIVE_SETUP_LIB__

_vsd_jq_bin='__JQ_BIN__'
_vsd_mounts_json='__ENABLED_MOUNTS_JSON__'
_vsd_replicas_json='__ENABLED_REPLICAS_JSON__'

# Create the top-level clouds/ directory tree.
mkdir -p "$HOME/clouds"

# Process mounts: ensure each mount point is a real directory.
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_local_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.localPath')"
  _cd_ensure_real_directory "$HOME/$_vsd_local_path" "$_vsd_local_path"
done < <(printf '%s\n' "$_vsd_mounts_json" | "$_vsd_jq_bin" -r -c '.[]')

# Process replicas: ensure each replica directory or symlink exists.
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_local_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.localPath')"
  _vsd_display_name="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.displayName')"
  _vsd_is_special_icloud="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.isSpecialICloud')"

  if [ "$_vsd_is_special_icloud" = "true" ]; then
    # macOS-only exception: iCloudReplica must point to native CloudDocs
    # storage so we do not duplicate Apple's iCloud integration with a
    # second managed tree.  Only reachable on Darwin (the isSpecialICloud
    # flag is set at Nix eval time based on pkgs.stdenv.isDarwin).
    _vsd_icloud_native_target="$HOME/Library/Mobile Documents"
    _vsd_icloud_replica_path="$HOME/$_vsd_local_path"

    if [ -L "$_vsd_icloud_replica_path" ]; then
      if [ "$(readlink "$_vsd_icloud_replica_path")" != "$_vsd_icloud_native_target" ]; then
        _vsd_legacy_target="$(readlink "$_vsd_icloud_replica_path")"
        rm "$_vsd_icloud_replica_path"
        ln -s "$_vsd_icloud_native_target" "$_vsd_icloud_replica_path"
        printf '%s\n' "cloud-drives ($_vsd_display_name): updated iCloudReplica symlink $_vsd_icloud_replica_path -> $_vsd_icloud_native_target (was $_vsd_legacy_target)."
      fi
    elif [ -e "$_vsd_icloud_replica_path" ]; then
      _vsd_migration_backup="$_vsd_icloud_replica_path.pre-native-icloud.$(date +%Y%m%d%H%M%S)"
      mv "$_vsd_icloud_replica_path" "$_vsd_migration_backup"
      ln -s "$_vsd_icloud_native_target" "$_vsd_icloud_replica_path"
      printf '%s\n' "cloud-drives ($_vsd_display_name): migrated $_vsd_icloud_replica_path to native iCloud symlink target $_vsd_icloud_native_target (backup: $_vsd_migration_backup)."
    else
      ln -s "$_vsd_icloud_native_target" "$_vsd_icloud_replica_path"
      printf '%s\n' "cloud-drives ($_vsd_display_name): linked $_vsd_icloud_replica_path -> $_vsd_icloud_native_target (native iCloud replica path)."
    fi
  else
    _cd_ensure_real_directory "$HOME/$_vsd_local_path" "$_vsd_display_name"
  fi
done < <(printf '%s\n' "$_vsd_replicas_json" | "$_vsd_jq_bin" -r -c '.[]')
