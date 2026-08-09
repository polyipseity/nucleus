#!/usr/bin/env bash
# Self-executing preparation of custom provision symlinks.
# Unprotects managed symlinks before linkGeneration.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_cps_manifest_path="$1"
_cps_jq_bin="$2"
_cps_link_paths_json="${3:-}"

_unprotect_managed_link() {
  _cps_link_path="$1"
  [ -n "$_cps_link_path" ] || return 0
  if [ -L "$_cps_link_path" ]; then
    _nucleus_unprotect_symlink "symlinks" "$_cps_link_path"
  fi
}

if [ -n "$_cps_link_paths_json" ]; then
  while IFS= read -r _cps_link_path; do
    _unprotect_managed_link "$_cps_link_path"
  done < <("$_cps_jq_bin" -r '.[]' <<<"$_cps_link_paths_json")
fi

if [ -f "$_cps_manifest_path" ]; then
  while IFS= read -r _cps_link_path; do
    _unprotect_managed_link "$_cps_link_path"
  done < <("$_cps_jq_bin" -r '.[]' "$_cps_manifest_path")
fi
