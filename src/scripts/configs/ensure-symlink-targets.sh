#!/usr/bin/env bash
# Create target directories for symlinks entries.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_nucleus_manifest_path="$1"
_nucleus_target_dirs_json="$2"
_nucleus_jq_bin="$3"
_nucleus_manifest_dir="$(dirname "$_nucleus_manifest_path")"
mkdir -p "$_nucleus_manifest_dir"

printf '%s\n' "$_nucleus_target_dirs_json" | "$_nucleus_jq_bin" -r '.[]' | while IFS= read -r _nucleus_path; do
  [ -n "$_nucleus_path" ] || continue
  mkdir -p "$(dirname "$_nucleus_path")"
done
