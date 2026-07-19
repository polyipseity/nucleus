# Self-executing preparation of custom provision symlinks.
# Sources symlink-hardening-lib.sh and unprotects managed symlinks before
# linkGeneration, using token placeholders substituted at Nix eval time.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

_cps_manifest_path="__MANIFEST_PATH__"
_cps_jq_bin="__JQ_BIN__"

if [ -f "$_cps_manifest_path" ]; then
  while IFS= read -r _cps_link_path; do
    [ -n "$_cps_link_path" ] || continue
    if [ -L "$_cps_link_path" ]; then
      _nucleus_unprotect_symlink "customProvisionSymlinks" "$_cps_link_path"
    fi
  done < <("$_cps_jq_bin" -r '.[]' "$_cps_manifest_path")
fi
