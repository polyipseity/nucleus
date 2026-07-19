# shellcheck shell=sh
# Build nix-index database in background if absent.
# Token: __NIX_INDEX_BIN__ (replaced with nix-index binary path by Nix replaceStrings).

set -eu

_db_file="$HOME/.cache/nix-index/files"
if [ ! -f "$_db_file" ]; then
  __NIX_INDEX_BIN__ >/dev/null 2>&1 &
  echo "linux: nix-index database build started in background; this may take a few minutes." >&2
fi
