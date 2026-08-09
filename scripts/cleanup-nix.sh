#!/usr/bin/env bash
# Remove stale `result` and `result-*` symlinks left by `nix build`,
# `nix run ... -o result`, or `nixos-generators`.
#
# Only removes symlinks — real files or directories with these names are
# preserved (with a warning) since they cannot be `result` artifacts.
#
# Exit codes:
#   0  on success (no stale artifacts, or all cleaned up)
#   1  on internal error (e.g. cannot determine repo root)
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
  /*) _self="$_target" ;;
  *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

usage() {
  usage_std "$(basename "$0")" "[--dry-run] [--help]" "Remove stale Nix build result symlinks (result, result-*) from the repo root."
}

_cnba_options=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --dry-run)
    _cnba_options="$_cnba_options --dry-run"
    shift
    ;;
  *)
    error "unsupported argument '$1'"
    usage >&2
    exit 1
    ;;
  esac
done

REPO_ROOT="$(derive_repo_root)"
export REPO_ROOT
# shellcheck source=../src/scripts/cleanup-nix-build-artifacts.sh
. "$SCRIPT_DIR/../src/scripts/cleanup-nix-build-artifacts.sh"
nuc_done
