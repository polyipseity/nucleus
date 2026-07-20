#!/usr/bin/env bash
# Build/update nix-index file database.
# Tokens: __NIX_INDEX_BIN__, __NIX_INDEX_MAX_AGE_DAYS__
set -euo pipefail

_db_file="$HOME/.cache/nix-index/files"
_max_age_days='__NIX_INDEX_MAX_AGE_DAYS__'

# Skip if DB exists and is within max-age window.
if [ -f "$_db_file" ]; then
  if [ -n "$_max_age_days" ] && [ -z "$(find "$_db_file" -mtime +"$_max_age_days")" ]; then
    exit 0
  fi
  # No max-age set (NixOS): only build when absent.
  [ -z "$_max_age_days" ] && exit 0
fi

# DB absent or stale: build it.
# Background the build when called from activation (no max-age).
if [ -z "$_max_age_days" ]; then
  __NIX_INDEX_BIN__ >/dev/null 2>&1 &
  echo "nix-index database build started in background; this may take a few minutes." >&2
else
  exec __NIX_INDEX_BIN__
fi
