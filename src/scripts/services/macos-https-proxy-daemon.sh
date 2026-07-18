# HTTPS proxy daemon — runs Caddy for all configured virtual hosts.
# Binaries and config path provided via Nix substitution at build time.
set -eu

state_root="/Users/Shared/https-proxy"
caddy_root="$state_root/caddy"
caddy_config_dir="$caddy_root/config"
caddy_data_dir="$caddy_root/data"
log_dir="$state_root/log"

mkdir -p "$caddy_config_dir" "$caddy_data_dir" "$log_dir"

export XDG_CONFIG_HOME="$caddy_config_dir"
export XDG_DATA_HOME="$caddy_data_dir"

exec __CADDY_BIN__ run --config __CADDYFILE__ --adapter caddyfile
