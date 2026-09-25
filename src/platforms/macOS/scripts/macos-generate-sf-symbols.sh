#!/usr/bin/env bash
# Generate the SF Symbols name list from the macOS SFSymbols private framework.
#
# SF Symbols is an Apple-only API, so the list is macOS-only data and is never
# committed; it is regenerated on every nucleus-apply into the macOS USER root's
# state directory. The sf-symbols skill greps that generated file instead of a
# committed copy, so it tracks whatever macOS version is installed.
#
# Two Apple plists back the list:
#   CoreGlyphs.bundle        public symbols
#   CoreGlyphsPrivate.bundle private symbols
# `plutil -extract symbols raw` prints the dictionary's keys, one name per line,
# so the `year_to_release` release-metadata section never leaks in the way the
# older `plutil -p | grep '=>'` recipe did. The private bundle also ships
# internal placeholders whose keys begin with a 32-character uppercase hex ID;
# those are filtered out, leaving names only.
#
# Usage: macos-generate-sf-symbols.sh <plutil-bin> <grep-bin> <sort-bin> <cmp-bin>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

_plutil_bin="$1"
_grep_bin="$2"
_sort_bin="$3"
_cmp_bin="$4"

_framework_resources="/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources"
_out_dir="${NUCLEUS_USER_ROOT}/state"
_out="${_out_dir}/sf-symbols.txt"

mkdir -p "$_out_dir"

_tmp="$(mktemp "${_out_dir}/sf-symbols.XXXXXX")"
trap 'rm -f "$_tmp"' EXIT

{
  "$_plutil_bin" -extract symbols raw -o - "${_framework_resources}/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
  "$_plutil_bin" -extract symbols raw -o - "${_framework_resources}/CoreGlyphsPrivate.bundle/Contents/Resources/name_availability.plist"
} | "$_grep_bin" -vE '^[0-9A-F]{32}' | LC_ALL=C "$_sort_bin" -u >"$_tmp"

# Idempotent: the output is deterministic, so a rerun on the same macOS leaves
# the file byte-identical and its mtime untouched.
if [ -f "$_out" ] && "$_cmp_bin" -s "$_tmp" "$_out"; then
  rm -f "$_tmp"
else
  mv -f "$_tmp" "$_out"
fi
