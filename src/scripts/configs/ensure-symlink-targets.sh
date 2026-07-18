# shellcheck shell=sh
# Create target directories for custom-provision-symlinks entries.
# Tokens substituted at build time.

set -eu

_nucleus_manifest_dir="$(dirname '__MANAGED_SYMLINK_MANIFEST_PATH__')"
mkdir -p "$_nucleus_manifest_dir"

echo '__SYMLINK_TARGET_DIRS_JSON__' | __JQ_BIN__ -r '.[]' | while IFS= read -r _nucleus_path; do
  [ -n "$_nucleus_path" ] || continue
  mkdir -p "$(dirname "$_nucleus_path")"
done
