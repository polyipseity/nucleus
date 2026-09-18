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

# rotate_fuse_t_logs MAXSIZE MAXFILES COMPRESS EXPIRY — rotate FUSE-T's own logs.
# FUSE-T writes them under a hardcoded per-user path outside the nucleus log root
# and never rotates them, so a crash-looping mount grows them without bound.
# WHY: rotate here rather than point FUSE-T at the nucleus log root — its config
# file is system-wide, so it cannot carry a per-user log path on a multi-user host.
rotate_fuse_t_logs() {
  local maxsize="$1" maxfiles="$2" compress="$3" expiry="$4"
  [ "$(uname -s)" = "Darwin" ] || return 0
  local dir="$HOME/Library/Logs/fuse-t"
  [ -d "$dir" ] || return 0
  # WHY: these logs belong to FUSE-T, not nucleus, and are not necessarily ours to
  # write; rotate_log_file hard-errors on an unwritable file, which would abort the
  # whole nucleus GC, so skip the directory instead.
  local fuse_t_file
  for fuse_t_file in "$dir" "$dir"/*.log "$dir/fuse-t.err"; do
    if [ -e "$fuse_t_file" ] && [ ! -w "$fuse_t_file" ]; then
      warn "skipping FUSE-T log rotation: '$fuse_t_file' is not writable"
      return 0
    fi
  done
  rotate_logs_in_directory "$dir" "$maxsize" "$maxfiles" "$compress"
  # WHY: rotate_logs_in_directory selects only *.log, and FUSE-T also writes fuse-t.err.
  rotate_log_file "$dir/fuse-t.err" "$maxsize" "$maxfiles" "$compress"
  expire_logs_in_directory "$dir" "$expiry"
}

rotate_logs_in_directory "$_lgu_log_dir" "$_lgu_maxsize" "$_lgu_maxfiles" "$_lgu_compress"
expire_logs_in_directory "$_lgu_log_dir" "$_lgu_expiry"
rotate_fuse_t_logs "$_lgu_maxsize" "$_lgu_maxfiles" "$_lgu_compress" "$_lgu_expiry"
