#!/usr/bin/env bash
# Rotate user-level nucleus log files.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

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
  _lgu_maxsize=10000000
  _lgu_maxfiles=4
  _lgu_compress=true
else
  require_command jq
  _lgu_maxsize="$(jq -r '.definitions.loggingEntry.properties.maxSize.default // 10000000' "$_services_schema_json")"
  _lgu_maxfiles="$(jq -r '.definitions.loggingEntry.properties.maxFiles.default // 4' "$_services_schema_json")"
  _lgu_compress="$(jq -r '.definitions.loggingEntry.properties.compress.default // "true"' "$_services_schema_json")"
fi

_lgu_log_dir="$(nucleus_log_dir)"
_lgu_expiry="${NUCLEUS_GC_EXPIRY:-7d}"

rotate_logs_in_directory "$_lgu_log_dir" "$_lgu_maxsize" "$_lgu_maxfiles" "$_lgu_compress"
expire_logs_in_directory "$_lgu_log_dir" "$_lgu_expiry"
