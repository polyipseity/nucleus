#!/usr/bin/env bash
# Install superpowers plugin via Copilot CLI (best-effort).
# Receives the copilot binary path as a store-path arg; skips gracefully
# when the binary is absent.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_csp_path_prepend="$1"
_csp_path_append="$2"
_csp_copilot_bin="$3"

# Add managed bin directories to PATH.
PATH="${_csp_path_prepend}$PATH${_csp_path_append}"
export PATH

# Skip if the Copilot CLI binary is not reachable.
if [ ! -x "$_csp_copilot_bin" ]; then
  say -l copilot-superpowers "copilot CLI not found; skipping superpowers install"
  exit 0
fi

# Add the superpowers marketplace (idempotent — re-adding is a no-op).
if ! "$_csp_copilot_bin" plugin marketplace add obra/superpowers-marketplace 2>/dev/null; then
  warn -l copilot-superpowers "failed to add superpowers marketplace (non-fatal)"
fi

# Install or update superpowers from the marketplace.
if ! "$_csp_copilot_bin" plugin install superpowers@superpowers-marketplace; then
  warn -l copilot-superpowers "failed to install superpowers plugin (non-fatal)"
fi

say -l copilot-superpowers "superpowers plugin install complete"
