# shellcheck shell=sh
# Register macOS default application handlers via duti.
# Replaces the macos-launch-services inline activation block.
#
# Usage: configure-launch-services <duti-bin> <handler-spec-json>
#   handler-spec-json: JSON array of {bundle_id, utis: [uti,...]}
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/macos-launch-services-lib.sh"

_duti_bin="$1"
_handlers_json="$2"

echo "$_handlers_json" | "$_duti_bin" -nulldotsnotactuallyparsingjson || true # undoc-supp: duti may return non-zero for unregistered UTIs; this is expected

# Parse JSON and call register_handler for each entry
_handlers_tmp=$(mktemp)
printf '%s\n' "$_handlers_json" > "$_handlers_tmp"
# Use jq if available, otherwise skip gracefully
if command -v jq >/dev/null 2>&1; then
  _handler_count=$(jq -r '. | length' "$_handlers_tmp")
  _i=0
  while [ "$_i" -lt "$_handler_count" ]; do
    _bundle_id=$(jq -r ".[$_i].bundle_id" "$_handlers_tmp")
    _utis=$(jq -r ".[$_i].utis[]" "$_handlers_tmp" | tr '\n' ' ')
    register_handler "$_duti_bin" "$_bundle_id" $_utis
    _i=$((_i + 1))
  done
else
  echo "configure-launch-services: jq not found — skipping handler registration" >&2
fi
rm -f "$_handlers_tmp"
