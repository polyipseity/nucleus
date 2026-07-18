# shellcheck shell=sh
# Finalize custom-provision-symlinks: protect each managed symlink and persist
# the manifest.  REPO_ROOT must be set by the caller (baked at build time by
# Nix).  The symlink-hardening library is sourced at runtime from the repo.
#
# Tokens:
#   __MANAGED_SYMLINK_MANIFEST_PATH__  — path to the managed symlink manifest
#   __SYMLINK_ENTRIES_JSON__           — JSON array of absolute symlink paths
#   __MANAGED_SYMLINK_MANIFEST_JSON__  — JSON content to write to the manifest
#   __JQ_BIN__                        — path to jq

set -eu
. "$REPO_ROOT/src/scripts/lib/symlink-hardening-lib.sh"

_nucleus_manifest_path='__MANAGED_SYMLINK_MANIFEST_PATH__'
_nucleus_manifest_dir="$(dirname "$_nucleus_manifest_path")"
mkdir -p "$_nucleus_manifest_dir"

echo '__SYMLINK_ENTRIES_JSON__' | __JQ_BIN__ -r '.[]' | while IFS= read -r _nucleus_link_path; do
  [ -n "$_nucleus_link_path" ] || continue
  if [ -L "$_nucleus_link_path" ]; then
    _nucleus_protect_symlink "customProvisionSymlinks" "$_nucleus_link_path"
  else
    echo "customProvisionSymlinks: warning — expected managed symlink at $_nucleus_link_path." >&2
  fi
done

cat > "$_nucleus_manifest_path" <<'EOF'
__MANAGED_SYMLINK_MANIFEST_JSON__
EOF
