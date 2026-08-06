#!/usr/bin/env bash
# HTTPS proxy daemon — runs Caddy for all configured virtual hosts.
# Config path provided as env var CADDYFILE_PATH or first positional arg.
# Caddy resolved from PATH.
# Usage: https-proxy-daemon.sh [caddyfile]
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_caddy_root="$(nucleus_caddy_state_dir)"
caddy_config_dir="$_caddy_root/config"
caddy_data_dir="$_caddy_root/data"

mkdir -p "$caddy_config_dir" "$caddy_data_dir"

export XDG_CONFIG_HOME="$caddy_config_dir"
export XDG_DATA_HOME="$caddy_data_dir"

caddyfile="${CADDYFILE_PATH:-${1:-}}"

exec caddy run --config "$caddyfile" --adapter caddyfile
