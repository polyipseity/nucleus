#!/usr/bin/env bash
# Create deterministic /etc/nucleus-bin/nvim symlink for vscode-neovim.
# Token: __NUCLEUS_NVIM_PATH__ (resolved by Nix at build time per host).
# When the token is unset (empty), resolve at runtime from /dev/console (macOS).
set -euo pipefail

_nvim_path='__NUCLEUS_NVIM_PATH__'

if [ -z "$_nvim_path" ]; then
  # Runtime resolution (macOS): get console user, resolve profile path.
  _console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo "")"
  if [ -n "$_console_user" ]; then
    _nvim_path="/etc/profiles/per-user/$_console_user/bin/nvim"
  fi
fi

if [ -n "$_nvim_path" ] && [ -x "$_nvim_path" ]; then
  /bin/mkdir -p /etc/nucleus-bin
  /bin/ln -sfn "$_nvim_path" /etc/nucleus-bin/nvim
fi
