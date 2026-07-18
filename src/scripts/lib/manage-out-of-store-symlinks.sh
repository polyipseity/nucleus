# shellcheck shell=sh
# Iterate a JSON array of paths and call the corresponding
# _nucleus_{unprotect,protect}_symlink function for each.
# Requires symlink-hardening-lib functions loaded separately.

_nucleus_unprotect_managed_paths() {
  _context="$1"
  _paths_json="$2"
  _jq_bin="$3"
  echo "$_paths_json" | "$_jq_bin" -r '.[]' | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _nucleus_unprotect_symlink "$_context" "$_p"
  done
}

_nucleus_protect_managed_paths() {
  _context="$1"
  _paths_json="$2"
  _jq_bin="$3"
  echo "$_paths_json" | "$_jq_bin" -r '.[]' | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _nucleus_protect_symlink "$_context" "$_p"
  done
}
