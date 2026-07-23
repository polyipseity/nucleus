#!/usr/bin/env bash
# Jellyfin media server daemon.
# State root, log dir, and binary path provided via env vars or positional args.
#   JELLYFIN_STATE_ROOT / $1
#   JELLYFIN_LOG_DIR / $2
#   JELLYFIN_BIN / $3
# Usage: jellyfin-daemon.sh [state_root] [log_dir] [jellyfin_bin]
set -eu

state_root="${JELLYFIN_STATE_ROOT:-${1:-/Users/Shared/Jellyfin}}"
log_dir="${JELLYFIN_LOG_DIR:-${2:-${HOME}/.local/state/nucleus/log/jellyfin}}"
jellyfin_bin="${JELLYFIN_BIN:-${3:-jellyfin}}"
shift 3 2>/dev/null || true # undoc-supp: expected failure when defaulting all positional args

config_dir="$state_root/config"
data_dir="$state_root/data"
cache_dir="$state_root/cache"

mkdir -p "$config_dir" "$data_dir" "$cache_dir" "$log_dir"

exec "$jellyfin_bin" \
  --configdir "$config_dir" \
  --datadir "$data_dir" \
  --cachedir "$cache_dir" \
  --logdir "$log_dir"
