#!/usr/bin/env sh
# caddy-trust.sh — Trust Caddy's local CA for local TLS clients.
#
# This script trusts Caddy's locally-managed CA root certificate so that
# `tls internal` reverse proxy targets are recognized without client-side
# certificate warnings. It applies generally to every local reverse proxy
# using the same Caddy PKI authority (not just Jellyfin).
#
# WHY a separate .sh file instead of inline shell in apply.sh:
#   The function is needed by multiple call sites, each with a different
#   privilege context (sudo on Darwin/NixOS system apply, user on
#   standalone Home Manager).  Extracting it avoids duplication and allows
#   independent shellcheck validation.
#
# Usage:
#   src/scripts/caddy-trust.sh sudo|user
#
# Arguments:
#   sudo — run `caddy trust` with sudo
#   user — run `caddy trust` as the current user
#
# Exit codes:
#   0 — CA trusted successfully
#   1 — caddy not found in PATH
#   2 — all 20 retry attempts exhausted

set -eu

if [ $# -ne 1 ]; then
  printf '%s\n' "Usage: $(basename "$0") sudo|user" >&2
  exit 2
fi
_ct_mode="$1"

if ! command -v caddy >/dev/null 2>&1; then
  printf '%s\n' 'caddy-trust: caddy not found in PATH; skipping local CA trust'
  exit 1
fi

_ct_attempt=0
while [ "$_ct_attempt" -lt 20 ]; do
  if [ "$_ct_mode" = "sudo" ]; then
    if sudo env "PATH=$PATH" caddy trust --address 127.0.0.1:2019; then
      printf '%s\n' 'caddy-trust: local CA trusted successfully'
      exit 0
    fi
  else
    if caddy trust --address 127.0.0.1:2019; then
      printf '%s\n' 'caddy-trust: local CA trusted successfully'
      exit 0
    fi
  fi

  _ct_attempt=$((_ct_attempt + 1))
  sleep 1
done

printf '%s\n' 'caddy-trust: failed to trust local CA from admin endpoint 127.0.0.1:2019; continuing without failing apply' >&2
exit 2
