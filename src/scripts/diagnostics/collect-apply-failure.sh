#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 collect-apply-failure

output="${1-}"
[ -n "$output" ] || {
  printf 'usage: collect-apply-failure <output-file>\n' >&2
  exit 2
}

{
  printf '=== nix version ===\n'
  nix --version 2>&1 || printf 'nix version query failed\n'
  printf '\n=== nix config ===\n'
  nix config show eval-cache keep-derivations keep-outputs min-free max-free 2>&1 || printf 'nix config query failed\n'
  printf '\n=== effective config files ===\n'
  for f in /etc/nix/nix.conf /etc/nix/nix.custom.conf; do
    printf -- '--- %s ---\n' "$f"
    if [ -f "$f" ]; then cat "$f"; else printf 'absent\n'; fi
  done
  printf '\n=== failing derivation ===\n'
  failing='/nix/store/0rz22bph811zkzy1z5xkfslj3zy19qj0-darwin-system-26.11.ff0e21a.drv'
  if [ -e "$failing" ]; then printf 'present\n'; else printf 'absent\n'; fi
  nix-store -q --hash "$failing" 2>&1 || printf 'nix-store query failed for failing derivation\n'
  printf '\n=== current generation deriver ===\n'
  current='/nix/store/l80mvrmsf16f5b7pjds539vnkn26abyn-darwin-system-26.11.ff0e21a.drv'
  if [ -e "$current" ]; then printf 'present\n'; else printf 'absent\n'; fi
  nix-store -q --hash "$current" 2>&1 || printf 'nix-store query failed for current derivation\n'
  printf '\n=== eval cache listing ===\n'
  ls -la "${HOME:?}/.cache/nix" 2>&1 || printf 'eval cache directory unavailable\n'
  printf '\n=== gc processes ===\n'
  ps -axo pid=,etime=,time=,command= 2>&1 || printf 'process list unavailable in this context\n'
} >"$output"
