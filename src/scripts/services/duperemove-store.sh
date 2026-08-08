#!/usr/bin/env bash
# Btrfs block-level deduplication for /nix/store on NixOS hosts.
# Invoked from scripts/gc.sh during weekly root GC (after nix-collect-garbage).
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_dry_run="${NUCLEUS_GC_DRY_RUN:-false}"
_hashfile="/var/lib/duperemove/hashfile"

if [ "$(uname -s)" != "Linux" ]; then
  exit 0
fi

if [ ! -d /nix/store ]; then
  exit 0
fi

_store_fstype="$(findmnt -n -o FSTYPE -T /nix/store)" || exit 0
if [ "$_store_fstype" != "btrfs" ]; then
  exit 0
fi

if ! command -v duperemove >/dev/null 2>&1; then
  error "duperemove is required on btrfs NixOS hosts but is not in PATH"
fi

if [ "$_dry_run" = true ]; then
  dry_run "would run duperemove -dr --hashfile=$_hashfile /nix/store"
  exit 0
fi

mkdir -p "$(dirname "$_hashfile")"
say "running duperemove on /nix/store"
duperemove -dr --hashfile="$_hashfile" /nix/store
