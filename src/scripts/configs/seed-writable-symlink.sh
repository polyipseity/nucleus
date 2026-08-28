#!/usr/bin/env bash
# Create a method-1 (writable) out-of-store symlink that points at the LIVE repo
# root, resolved at activation time — NOT at the eval-time Nix store snapshot.
#
# MECHANISM (read before changing this file):
#   Method-1 symlinks MUST point at the LIVE repo root, resolved at activation
#   time via `derive_repo_root`. Never bake `repoRoot` (a read-only
#   `/nix/store/*-source` snapshot produced by the `repoRoot = ../.` path literal
#   in flake.nix) as the target — that breaks write-through and the
#   "repo changes take effect without rebuild" contract (GUI writes fail with
#   EACCES -> HTTP 500). This helper generalizes the already-correct
#   `macos-configure-linearmouse.sh` pattern (mkdir -p + ln -sf) so every
#   repo-sourced method-1 link resolves to the live working tree.
#
#   This script ONLY creates/relinks the symlink. The writable-vs-immutable
#   decision lives SOLELY in `managedSymlinkPaths` (src/modules/home.nix) and is
#   applied by the `protect-out-of-store-symlinks` activation entry. Do NOT pass a
#   writable flag here or call `_nucleus_protect_symlink` / `_nucleus_unprotect_symlink`
#   except for the one migration `rm` below — doing so duplicates `managedSymlinkPaths`
#   and risks divergence. The existing `protect-out-of-store-symlinks` entry
#   re-hardens per `managedSymlinkPaths` after this link exists.
#
#   Read-only-safe: this script never writes into the repo; it only creates the
#   symlink under the user's home (or wherever the caller's target path lives).
#
# Usage: seed-writable-symlink.sh <target-path> <repo-rel-path> [hostName]
#   <target-path>    Absolute path of the symlink to create (e.g.
#                    $HOME/.config/camilladsp/configs).
#   <repo-rel-path>  Repo-relative source path (e.g.
#                    src/modules/configs/camilladsp/configs/MacBook). The caller
#                    bakes any host key into this path; hostName is accepted only
#                    for diagnostics.
#   [hostName]       Optional. Used only for host-keyed config dirs; defaults to
#                    $NUCLEUS_HOST when unset.
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

# Resolve the LIVE repo root. derive_repo_root fails loudly (returns non-zero and
# prints to stderr) when it cannot determine the root — no silent default, per the
# no-fallbacks rule. Capture into a variable so an empty result is also rejected.
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
  # Migration: target is a symlink to a DIFFERENT (broken store) path. Clear the
  # immutable flag so it can be removed, then relink below. This is the only
  # protect/unprotect call allowed here — it is strictly for migration, not for
  # owning the writable/immutable decision (that lives in managedSymlinkPaths).
  _nucleus_unprotect_symlink "${_host_name:-nucleus}" "$_target_path"
  rm -f "$_target_path"
elif [ -e "$_target_path" ]; then
  # Refuse to clobber a real file or directory that is not a symlink.
  die "seed-writable-symlink: $_target_path exists and is not a symlink; fix manually and re-apply"
fi

ln -sf "$sourcePath" "$_target_path"
