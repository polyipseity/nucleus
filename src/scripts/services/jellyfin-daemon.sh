#!/usr/bin/env bash
# Jellyfin media server daemon.
# State root, log dir, and binary path provided via Nix substitution at build time.
set -eu

state_root="__JELLYFIN_STATE_ROOT__"
config_dir="$state_root/config"
data_dir="$state_root/data"
cache_dir="$state_root/cache"
log_dir="__JELLYFIN_LOG_DIR__"

mkdir -p "$config_dir" "$data_dir" "$cache_dir" "$log_dir"

exec __JELLYFIN_BIN__ \
  --configdir "$config_dir" \
  --datadir "$data_dir" \
  --cachedir "$cache_dir" \
  --logdir "$log_dir"
