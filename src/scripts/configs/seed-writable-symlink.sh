#!/usr/bin/env bash
# Create a method-1 (writable) out-of-store symlink pointing at the LIVE repo root.
#
# WHY the live root: `repoRoot = ../.` in flake.nix evaluates to a read-only
# /nix/store snapshot, which breaks write-through (GUI writes fail EACCES).
# derive_repo_root resolves the live tree at activation time instead.
#
# WHY no writable flag here: the writable-vs-immutable decision belongs to
# `managedSymlinkPaths` (src/modules/home.nix), applied by the
# `protect-out-of-store-symlinks` entry. Only the migration unlink below touches
# protection.
#
# Usage: seed-writable-symlink.sh <target-path> <repo-rel-path> [hostName]
#   <target-path>    Absolute symlink path to create.
#   <repo-rel-path>  Repo-relative source path; the caller bakes any host key in.
#   [hostName]       Optional, for host-keyed config dirs. Defaults to $NUCLEUS_HOST.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

if [ "$#" -lt 2 ]; then
  die "usage: $(basename "$0") <target-path> <repo-rel-path> [hostName]"
fi

_target_path="$1"
_repo_rel_path="$2"
_host_name="${3:-${NUCLEUS_HOST:-}}"

# derive_repo_root fails loudly rather than defaulting, so an empty result is a bug.
liveRoot="$(derive_repo_root)" || exit 1
if [ -z "$liveRoot" ]; then
  die "seed-writable-symlink: could not resolve live repo root (derive_repo_root returned empty); set NUCLEUS_REPO_ROOT or run from within the nucleus repo"
fi

sourcePath="$liveRoot/$_repo_rel_path"

# Never create a dangling symlink: the source must exist in the live repo.
if [ ! -e "$sourcePath" ]; then
  die "seed-writable-symlink: source path does not exist: $sourcePath (repo-rel-path: $_repo_rel_path)"
fi

targetDir="$(dirname "$_target_path")"
mkdir -p "$targetDir"

# Idempotent: if the target is already a symlink to the live source, no-op.
if [ -L "$_target_path" ]; then
  _existing_target="$(readlink "$_target_path")"
  if [ "$_existing_target" = "$sourcePath" ]; then
    exit 0
  fi
  # WHY the unprotect: the stale link may be immutable. This is the only
  # protect/unprotect call allowed here.
  _nucleus_unprotect_symlink "${_host_name:-nucleus}" "$_target_path"
  rm -f "$_target_path"
elif [ -e "$_target_path" ]; then
  # WHY die: clobbering a real file is not recoverable.
  die "seed-writable-symlink: $_target_path exists and is not a symlink; fix manually and re-apply"
fi

ln -sf "$sourcePath" "$_target_path"
