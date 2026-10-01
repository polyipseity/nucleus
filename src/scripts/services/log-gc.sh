#!/usr/bin/env bash
# Rotate one nucleus log tree, selected by scope.
# Usage: log-gc.sh <user|system>
# The system tree is root-owned (linux-builder, service-watchdog), so its callers
# run this script in the system domain; the user tree runs as the user.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/log-expiry.sh
. "$SCRIPT_DIR/../lib/log-expiry.sh"

_lgc_scope="${1:-}"
case "$_lgc_scope" in
user) _lgc_log_dir="$(nucleus_log_dir)" ;;
system) _lgc_log_dir="$(nucleus_system_log_dir)" ;;
*) die "usage: log-gc.sh <user|system>" ;;
esac

# derive_repo_root() resolves NUCLEUS_REPO_ROOT when it is a live path and
# rejects Nix store snapshots; an unresolvable root falls through to the
# hardcoded defaults below.
if ! _repo_root="$(derive_repo_root)"; then
  warn "repo root unresolvable; using hardcoded log rotation defaults."
  _repo_root=""
fi

_services_schema_json="${_repo_root}/src/modules/services.schema.json"
if [ ! -f "$_services_schema_json" ]; then
  warn "services.schema.json not found; using hardcoded log rotation defaults"
  _lgc_maxsize=10000000
  _lgc_maxfiles=4
  _lgc_compress=true
else
  require_command jq
  _lgc_maxsize="$(jq -r '.definitions.loggingEntry.properties.maxSize.default // 10000000' "$_services_schema_json")"
  _lgc_maxfiles="$(jq -r '.definitions.loggingEntry.properties.maxFiles.default // 4' "$_services_schema_json")"
  _lgc_compress="$(jq -r '.definitions.loggingEntry.properties.compress.default // "true"' "$_services_schema_json")"
fi

rotate_logs_in_directory "$_lgc_log_dir" "$_lgc_maxsize" "$_lgc_maxfiles" "$_lgc_compress"
expire_logs_in_directory "$_lgc_log_dir" "$(resolve_log_expiry)"
