#!/usr/bin/env bash
# Open host documentation via the OS-default URL handler.
# Variables below are substituted via Nix replaceStrings at build time.
# When tokens remain literal (writable symlink deployment), fall back to
# runtime resolution via NUCLEUS_REPO_ROOT and xdg-open.
set -eu

_opener='__MANUAL_OPENER__'
_path='__HOST_MANUAL_PATH__'

if [ "$_opener" = '__MANUAL_OPENER__' ]; then
  # Writable-symlink mode (tokens not substituted by Nix).
  _opener=xdg-open
  _path="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set}/src/hosts/NixOS/MANUAL.md"
fi

exec "$_opener" "$_path"
