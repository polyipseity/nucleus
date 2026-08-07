#!/usr/bin/env bash
# Print a Nix store space baseline report: closure sizes, generation count,
# GC roots, stale result symlinks, and linux-builder VM store usage (macOS).
set -euo pipefail

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
  usage_std "$(basename "$0")" "[--help]" "Print Nix store space audit baseline metrics."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
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
# shellcheck source=../src/scripts/lib/audit-store-space.sh
. "$SCRIPT_DIR/../src/scripts/lib/audit-store-space.sh"
audit_store_space_report
nuc_done
