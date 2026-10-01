#!/usr/bin/env bash
# shellcheck shell=bash
# provision-data-directory.sh - create ~/data entries from a JSON manifest.
# Never deletes: an existing file, dir, or symlink is left alone.
#
# Usage: provision-data-directory.sh <homedir> <manifest-json> <jq-bin>
# Ops: dir, file, symlink.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_homedir="$1"
_manifest="$2"
_jq_bin="${3:-jq}"
_data_dir="${_homedir}/data"

mkdir -p "$_data_dir"

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
