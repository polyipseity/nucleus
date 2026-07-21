# shellcheck shell=sh
# Finalize custom-provision-symlinks: protect each managed symlink and persist
# the manifest.  symlink-hardening-lib.sh is inlined at build time via
# builtins.readFile.
#
# Variables below are substituted via Nix replaceStrings at build time.

set -eu

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
