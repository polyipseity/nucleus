#!/usr/bin/env bash
# Daily .DS_Store cleanup for ~/dev.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

DEV_ROOT="$HOME/dev"
removed_count=0

# Create the canonical dev root lazily so the maintenance timer remains
# safe even before the first repo checkout populates ~/dev.
mkdir -p "$DEV_ROOT"

while IFS= read -r -d "" ds_store_path; do
  rm "$ds_store_path"
  removed_count=$((removed_count + 1))
done < <(
  find "$DEV_ROOT" -name ".DS_Store" -type f -print0
)

if [ "$removed_count" -gt 0 ]; then
  say "removed $removed_count .DS_Store files from ~/dev."
fi
