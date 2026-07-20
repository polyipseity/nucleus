# shellcheck shell=sh
# Verify archiving stack: 7z CLI and Keka.app registration.
# Token: __P7ZIP_BIN__ (replaced with p7zip binary path by Nix replaceStrings).

set -eu

# Verify 7z CLI is available and functional using direct Nix store path.
# Do not rely on PATH lookup since Home Manager activation runs in a minimal
# shell that may not have nix-darwin system package paths available yet.
if [ ! -x "__P7ZIP_BIN__" ]; then
  echo "macos: warning — 7z binary not found at __P7ZIP_BIN__; archive extraction may fail." >&2
elif ! "__P7ZIP_BIN__" --help >/dev/null 2>&1; then
  echo "macos: warning — 7z exists but --help failed; archive handling may be broken." >&2
fi

# Verify Keka application is installed and registered.
if [ ! -d "/Applications/Keka.app" ]; then
  echo "macos: warning — Keka.app not found in /Applications; GUI archiving unavailable." >&2
fi
