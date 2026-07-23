#!/usr/bin/env bash
# Open host documentation via the OS-default URL handler.
# Path provided as first positional arg (Nix build) or resolved at runtime
# via NUCLEUS_REPO_ROOT (writable-symlink mode).
set -eu

_path="${1:-}"
if [ -z "$_path" ]; then
  # Writable-symlink mode (no positional arg).
  _path="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set}/src/hosts/NixOS/MANUAL.md"
fi

exec xdg-open "$_path"
