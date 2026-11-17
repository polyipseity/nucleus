#!/usr/bin/env bash
# Create deterministic /etc/nucleus/bin/nvim symlink for vscode-neovim.
# When the arg is empty, resolve at runtime from /dev/console (macOS).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 launch-nvim

_nvim_path="$1"

if [ -z "$_nvim_path" ]; then
  # Runtime resolution (macOS): get console user, resolve profile path.
  _console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo "")"
  if [ -n "$_console_user" ]; then
    _nvim_path="/etc/profiles/per-user/$_console_user/bin/nvim"
  fi
fi

if [ -n "$_nvim_path" ] && [ -x "$_nvim_path" ]; then
  /bin/mkdir -p /etc/nucleus/bin
  /bin/ln -sfn "$_nvim_path" /etc/nucleus/bin/nvim
fi
