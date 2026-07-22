#!/usr/bin/env bash
# Verify archiving stack: 7z CLI and Keka.app registration.

set -euo pipefail


_p7zip_bin="$1"

# Verify 7z CLI is available and functional using direct Nix store path.
# Do not rely on PATH lookup since Home Manager activation runs in a minimal
# shell that may not have nix-darwin system package paths available yet.
if [ ! -x "$_p7zip_bin" ]; then
  echo "macos: warning — 7z binary not found at $_p7zip_bin; archive extraction may fail." >&2
elif ! "$_p7zip_bin" --help >/dev/null 2>&1; then
  echo "macos: warning — 7z exists but --help failed; archive handling may be broken." >&2
fi

# Verify Keka application is installed and registered.
if [ ! -d "/Applications/Keka.app" ]; then
  echo "macos: warning — Keka.app not found in /Applications; GUI archiving unavailable." >&2
fi
