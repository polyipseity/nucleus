#!/usr/bin/env bash
# Finalize custom-provision-symlinks: protect each managed symlink and persist
# the manifest.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_nucleus_manifest_path="$1"
_nucleus_jq_bin="$2"
_nucleus_symlink_entries_json="$3"
_nucleus_manifest_json="$4"
_nucleus_manifest_dir="$(dirname "$_nucleus_manifest_path")"
mkdir -p "$_nucleus_manifest_dir"

printf '%s\n' "$_nucleus_symlink_entries_json" | "$_nucleus_jq_bin" -r '.[]' | while IFS= read -r _nucleus_link_path; do
  [ -n "$_nucleus_link_path" ] || continue
  if [ -L "$_nucleus_link_path" ]; then
    _nucleus_protect_symlink "customProvisionSymlinks" "$_nucleus_link_path"
  else
    echo "customProvisionSymlinks: warning — expected managed symlink at $_nucleus_link_path." >&2
  fi
done

printf '%s\n' "$_nucleus_manifest_json" > "$_nucleus_manifest_path"
