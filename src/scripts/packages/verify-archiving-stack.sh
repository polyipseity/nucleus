#!/usr/bin/env bash
# Verify archiving stack: 7z CLI and Keka.app registration.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_p7zip_bin="$1"

# Verify 7z CLI is available and functional using direct Nix store path.
# Do not rely on PATH lookup since Home Manager activation runs in a minimal
# shell that may not have nix-darwin system package paths available yet.
if [ ! -x "$_p7zip_bin" ]; then
  warn -l macos "7z binary not found at $_p7zip_bin; archive extraction may fail."
elif ! "$_p7zip_bin" --help >/dev/null 2>&1; then
  warn -l macos "7z exists but --help failed; archive handling may be broken."
fi

# Verify Keka application is installed and registered.
if [ ! -d "/Applications/Keka.app" ]; then
  warn -l macos "Keka.app not found in /Applications; GUI archiving unavailable."
fi
