#!/usr/bin/env bash
# Finalize symlinks: protect each managed symlink and persist
# the manifest.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
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
    _nucleus_protect_symlink "symlinks" "$_nucleus_link_path"
  else
    warn -l symlinks "warning — expected managed symlink at $_nucleus_link_path."
  fi
done

printf '%s\n' "$_nucleus_manifest_json" >"$_nucleus_manifest_path"
