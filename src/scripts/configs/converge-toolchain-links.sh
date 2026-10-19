#!/usr/bin/env bash
# Converge the SYSTEM-root toolchain symlink farm from a JSON name->target map.
#
# Every env-catalog toolchain value (CC, DEVELOPER_DIR, SDKROOT, ...) points into
# this directory, so each link is repointed to the current generation's store
# path on every apply and `nix-collect-garbage` can never leave an exported value
# dangling. The target derivations are interpolated by the calling module, which
# keeps them alive in the system closure for as long as the links reference them.
#
# Usage: converge-toolchain-links.sh <jq-bin> <link-dir> <targets-json>
#   <jq-bin>        Store path to the jq binary (activation PATH is isolated).
#   <link-dir>      Absolute directory holding the toolchain symlinks.
#   <targets-json>  JSON object mapping link name -> store target path.
#
# Exits non-zero on any conflict (a real file where a link belongs, a missing
# target, an unprotect/protect failure); it never warns past a broken apply.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

if [ "$#" -ne 3 ]; then
  die "usage: $(basename "$0") <jq-bin> <link-dir> <targets-json>"
fi

_cts_jq_bin="$1"
_cts_link_dir="$2"
_cts_targets_json="$3"

mkdir -p "$_cts_link_dir"

# Names declared by this generation, accumulated in the current shell (process
# substitution, not a pipe) so the stale sweep below can see them.
_cts_valid_names=""

while IFS=$'\t' read -r _cts_name _cts_target; do
  [ -n "$_cts_name" ] || continue
  _cts_link="$_cts_link_dir/$_cts_name"
  if [ ! -e "$_cts_target" ]; then
    die "target for $_cts_name does not exist: $_cts_target"
  fi
  # Already correct: record the name and skip the churn.
  if [ -L "$_cts_link" ] && [ "$(readlink "$_cts_link")" = "$_cts_target" ]; then
    _cts_valid_names="$_cts_valid_names $_cts_name"
    continue
  fi
  # A real file where a symlink belongs is not recoverable by an apply.
  if [ -e "$_cts_link" ] && [ ! -L "$_cts_link" ]; then
    die "$_cts_link exists and is not a symlink; refusing to clobber it"
  fi
  # The stale link may be immutable from the previous apply's protect pass.
  _nucleus_unprotect_symlink "toolchains" "$_cts_link"
  rm -f "$_cts_link"
  ln -s "$_cts_target" "$_cts_link"
  _nucleus_protect_symlink "toolchains" "$_cts_link"
  echo "toolchains: linked $_cts_link -> $_cts_target"
  _cts_valid_names="$_cts_valid_names $_cts_name"
done < <("$_cts_jq_bin" -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$_cts_targets_json")

# Drop toolchain links a prior generation declared but this one does not: the
# directory is ours, so a lingering name is stale by definition.
find "$_cts_link_dir" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _cts_candidate; do
  _cts_cname="$(basename "$_cts_candidate")"
  case " $_cts_valid_names " in
  *" $_cts_cname "*) continue ;;
  esac
  _nucleus_unprotect_symlink "toolchains" "$_cts_candidate"
  rm "$_cts_candidate"
  echo "toolchains: removed stale symlink $_cts_cname (no longer declared)"
done
