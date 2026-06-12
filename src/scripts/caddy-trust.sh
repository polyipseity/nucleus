#!/usr/bin/env bash
# src/scripts/caddy-trust.sh — Trust Caddy's local CA for local TLS clients.
#
# Trusts Caddy's locally-managed CA root certificate so that `tls internal`
# reverse proxy targets are recognized without client-side certificate
# warnings. Applies generally to every local reverse proxy using the same
# Caddy PKI authority.
#
# WHY a separate .sh file: needed by multiple call sites with different
# privilege contexts (sudo on Darwin/NixOS, user on standalone Home Manager).
# Extracting it avoids duplication and allows independent shellcheck
# validation.
#
# Arguments:
#   sudo          Run `caddy trust` with sudo.
#   user          Run `caddy trust` as the current user.
#
# Environment variables:
#   (none)        No environment variables used.
#
# Exit conditions:
#   0 — CA trusted successfully.
#   1 — caddy not found in PATH.
#   2 — all 20 retry attempts exhausted.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

usage() {
  usage_std "$(basename "$0")" "{sudo|user}" "Trust the Caddy CA certificate for the current user or system-wide."
  cat <<'EOF'
  -h, --help    Show this help message and exit
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [ $# -ne 1 ]; then
  usage >&2
  exit 2
fi
_ct_mode="$1"

if ! command -v caddy >/dev/null 2>&1; then
  printf '%s\n' 'caddy-trust: caddy not found in PATH; skipping local CA trust'
  exit 1
fi

REPO_ROOT="$(resolve_nucleus_root)"
_ct_admin_addr="$(jq -r '.caddy.network.admin | "\(.host):\(.port)"' "$REPO_ROOT/src/modules/services.json" 2>/dev/null || echo '127.0.0.1:2019')"

_ct_attempt=0
while [ "$_ct_attempt" -lt 20 ]; do
  if [ "$_ct_mode" = "sudo" ]; then
    if sudo env "PATH=$PATH" caddy trust --address "$_ct_admin_addr"; then
      printf '%s\n' 'caddy-trust: local CA trusted successfully'
      exit 0
    fi
  else
    if caddy trust --address "$_ct_admin_addr"; then
      printf '%s\n' 'caddy-trust: local CA trusted successfully'
      exit 0
    fi
  fi

  _ct_attempt=$((_ct_attempt + 1))
  sleep 1
done

printf '%s\n' "caddy-trust: failed to trust local CA from admin endpoint $_ct_admin_addr; continuing without failing apply" >&2
exit 2
