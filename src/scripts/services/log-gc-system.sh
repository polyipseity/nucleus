#!/usr/bin/env bash
# Rotate system-level nucleus log files as root.
# User-context gc cannot rotate root-owned daemon logs (linux-builder,
# service-watchdog); this service runs in the system domain instead.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# derive_repo_root() resolves NUCLEUS_REPO_ROOT when it is a live path and
# rejects Nix store snapshots; an unresolvable root falls through to the
# hardcoded defaults below.
if ! _repo_root="$(derive_repo_root 2>/dev/null)"; then
  _repo_root=""
fi

_services_schema_json="${_repo_root}/src/modules/services.schema.json"
if [ ! -f "$_services_schema_json" ]; then
  warn "services.schema.json not found; using hardcoded log rotation defaults"
  _lgs_maxsize=10000000
  _lgs_maxfiles=4
  _lgs_compress=true
else
  require_command jq
  _lgs_maxsize="$(jq -r '.definitions.loggingEntry.properties.maxSize.default // 10000000' "$_services_schema_json")"
  _lgs_maxfiles="$(jq -r '.definitions.loggingEntry.properties.maxFiles.default // 4' "$_services_schema_json")"
  _lgs_compress="$(jq -r '.definitions.loggingEntry.properties.compress.default // "true"' "$_services_schema_json")"
fi

rotate_logs_in_directory "$(nucleus_system_log_dir)" "$_lgs_maxsize" "$_lgs_maxfiles" "$_lgs_compress"
expire_logs_in_directory "$(nucleus_system_log_dir)" "${NUCLEUS_GC_EXPIRY:-7d}"
