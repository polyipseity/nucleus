# shellcheck shell=bash
# src/scripts/agents/install-playwright-chromium.sh — Install Playwright Chromium for hermes-agent.
#
# Runs `npx playwright install --with-deps chromium` in the hermes-agent
# environment. Idempotent: skips if chromium is already installed.
#
# Usage: install-playwright-chromium.sh <hermes-store-path>
#   hermes-store-path: path to the hermes-agent nix store (contains bin/hermes)
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_hermes_store_path="$1"

# Check if chromium is already installed.
# shellcheck disable=SC2012 # reason: using ls to check for chromium directory
if ls -d "$HOME/.cache/ms-playwright/chromium-"* >/dev/null 2>&1; then
  notice "Playwright Chromium already installed — skipping"
  exit 0
fi

# Find node/npx in the hermes venv.
_npx_bin="${_hermes_store_path}/bin/npx"
if [ ! -x "$_npx_bin" ]; then
  # Fallback: try PATH
  _npx_bin="$(command -v npx 2>/dev/null || true)"
  if [ -z "$_npx_bin" ]; then
    error "npx not found — cannot install Playwright Chromium"
    exit 1
  fi
fi

notice "installing Playwright Chromium..."
"$_npx_bin" playwright install --with-deps chromium
notice "Playwright Chromium installed"
