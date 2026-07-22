#!/usr/bin/env bash
# Build/update nix-index file database.
# CLI args: nix_index_bin max_age_days
set -euo pipefail


_uni_nix_index_bin="$1"
_uni_max_age_days="$2"

_db_file="$HOME/.cache/nix-index/files"

# Skip if DB exists and is within max-age window.
if [ -f "$_db_file" ]; then
  if [ -n "$_uni_max_age_days" ] && [ -z "$(find "$_db_file" -mtime +"$_uni_max_age_days")" ]; then
    exit 0
  fi
  # No max-age set (NixOS): only build when absent.
  [ -z "$_uni_max_age_days" ] && exit 0
fi

# DB absent or stale: build it.
# Background the build when called from activation (no max-age).
if [ -z "$_uni_max_age_days" ]; then
  "$_uni_nix_index_bin" >/dev/null 2>&1 &
  echo "nix-index database build started in background; this may take a few minutes." >&2
else
  exec "$_uni_nix_index_bin"
fi
