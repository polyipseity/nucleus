#!/usr/bin/env bash
# HTTPS proxy daemon — runs Caddy for all configured virtual hosts.
# Config path provided as first positional arg. Caddy resolved from PATH.
# Usage: https-proxy-daemon.sh <caddyfile>
set -eu

state_root="/Users/Shared/https-proxy"
caddy_root="$state_root/caddy"
caddy_config_dir="$caddy_root/config"
caddy_data_dir="$caddy_root/data"
log_dir="$state_root/log"

mkdir -p "$caddy_config_dir" "$caddy_data_dir" "$log_dir"

export XDG_CONFIG_HOME="$caddy_config_dir"
export XDG_DATA_HOME="$caddy_data_dir"

caddyfile="${1:-}"

exec caddy run --config "$caddyfile" --adapter caddyfile
