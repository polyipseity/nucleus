# shellcheck shell=sh
# Legacy symlink → directory migration helpers for cloud drive setup.
# Required by the Nix-generated per-entry loops in cloudDrivesSetup.

# Replace a legacy symlink mountpoint (e.g. old /Volumes indirection from
# an earlier provisioning scheme) with a managed real directory so that
# FSKit/direct-path mounts have a writable target.  Idempotent: if the
# path is already a real directory, this is a no-op.
# Usage: _cd_ensure_real_directory "$HOME/path/to/mountpoint" "mount display name"
_cd_ensure_real_directory() {
  _cd_path="$1"
  _cd_name="$2"

  if [ -L "$_cd_path" ]; then
    _cd_legacy_target="$(readlink "$_cd_path")"
    rm "$_cd_path"
    mkdir -p "$_cd_path"
    printf '%s\n' "cloud-drives (${_cd_name}): replaced legacy symlink $_cd_path -> $_cd_legacy_target with a managed directory."
  else
    mkdir -p "$_cd_path"
  fi
}
