# Jellyfin media server daemon.
# Tokens substituted at build time by Nix:
#   __JELLYFIN_STATE_ROOT__, __JELLYFIN_LOG_DIR__, __JELLYFIN_BIN__
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
