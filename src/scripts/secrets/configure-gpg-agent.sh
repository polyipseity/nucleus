#!/usr/bin/env bash
# Configure GnuPG agent with pinentry-mac for macOS console user.
# CLI args: pinentry_mac_bin
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_cga_pinentry_mac_bin="$1"

# /dev/console may not exist (headless/SSH session); empty result means no console user, handled downstream.
_console_home="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
if [ -n "$_console_home" ] && [ "$_console_home" != "/Users/root" ]; then
  /bin/mkdir -p "$_console_home/.gnupg"
  /bin/chmod 700 "$_console_home/.gnupg"
  echo "pinentry-program $_cga_pinentry_mac_bin" > "$_console_home/.gnupg/gpg-agent.conf"
  echo "allow-loopback-pinentry" >> "$_console_home/.gnupg/gpg-agent.conf"
fi
