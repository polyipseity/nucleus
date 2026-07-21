# Self-executing preparation of custom provision symlinks.
# Unprotects managed symlinks before linkGeneration.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

_cps_manifest_path="$1"
_cps_jq_bin="$2"

if [ -f "$_cps_manifest_path" ]; then
  while IFS= read -r _cps_link_path; do
    [ -n "$_cps_link_path" ] || continue
    if [ -L "$_cps_link_path" ]; then
      _nucleus_unprotect_symlink "customProvisionSymlinks" "$_cps_link_path"
    fi
  done < <("$_cps_jq_bin" -r '.[]' "$_cps_manifest_path")
fi
