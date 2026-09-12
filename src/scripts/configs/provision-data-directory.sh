# shellcheck shell=bash
# src/scripts/configs/provision-data-directory.sh — Centralized ~/data provisioning.
#
# Ensures ~/data exists and creates folders, files, and symlinks as specified
# in a JSON manifest. Must NEVER delete anything. If a target already exists
# (file, dir, or symlink), it is left untouched.
#
# Usage: provision-data-directory.sh <homedir> <manifest-json> <jq-bin>
#   homedir:       user's home directory (e.g. /Users/alice)
#   manifest-json: JSON array of operations (see below)
#   jq-bin:        path to jq binary
#
# Manifest format:
#   [{"op": "dir", "path": "hermes-agent"},
#    {"op": "file", "path": "hermes-agent/SOUL.md", "content": "..."},
#    {"op": "symlink", "path": "/Users/alice/.hermes/SOUL.md", "target": "/Users/alice/data/hermes-agent/SOUL.md"}]
#
# Operations:
#   dir     — mkdir -p <homedir>/data/<path> (no-op if exists)
#   file    — create <homedir>/data/<path> with content (no-op if exists)
#   symlink — create symlink at <path> pointing to <target> (no-op if exists)
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_homedir="$1"
_manifest="$2"
_jq_bin="${3:-jq}"
_data_dir="${_homedir}/data"

# Ensure ~/data exists.
mkdir -p "$_data_dir"

# Process each manifest entry.
_count=$(echo "$_manifest" | "$_jq_bin" 'length')
_i=0
while [ "$_i" -lt "$_count" ]; do
  _op=$(echo "$_manifest" | "$_jq_bin" -r ".[$_i].op")
  _path=$(echo "$_manifest" | "$_jq_bin" -r ".[$_i].path")

  case "$_op" in
  dir)
    _target="${_data_dir}/${_path}"
    if [ ! -d "$_target" ]; then
      mkdir -p "$_target"
      notice "created directory: ${_path}"
    fi
    ;;
  file)
    _target="${_data_dir}/${_path}"
    if [ ! -f "$_target" ]; then
      _content=$(echo "$_manifest" | "$_jq_bin" -r ".[$_i].content")
      _parent=$(dirname "$_target")
      mkdir -p "$_parent"
      printf '%s' "$_content" >"$_target"
      notice "created file: ${_path}"
    fi
    ;;
  symlink)
    _link_path=$(echo "$_manifest" | "$_jq_bin" -r ".[$_i].path")
    _link_target=$(echo "$_manifest" | "$_jq_bin" -r ".[$_i].target")
    if [ ! -e "$_link_path" ] && [ ! -L "$_link_path" ]; then
      _link_parent=$(dirname "$_link_path")
      mkdir -p "$_link_parent"
      ln -s "$_link_target" "$_link_path"
      notice "created symlink: ${_link_path} -> ${_link_target}"
    fi
    ;;
  *)
    warn "unknown op: ${_op} (skipped)"
    ;;
  esac

  _i=$((_i + 1))
done

notice "data-directory provisioning complete"
