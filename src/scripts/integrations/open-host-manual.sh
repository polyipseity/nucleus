#!/usr/bin/env bash
# Open host documentation via the OS-default URL handler.
# Path provided via NUCLEUS_MANUAL_PATH env var or first positional arg (Nix build)
# or resolved at runtime via NUCLEUS_REPO_ROOT (writable-symlink mode).
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 open-host-manual

_path="${NUCLEUS_MANUAL_PATH:-${1:-}}"
if [ -z "$_path" ]; then
  # Writable-symlink mode (no positional arg).
  _path="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set}/src/hosts/NixOS/MANUAL.md"
fi

exec xdg-open "$_path"
