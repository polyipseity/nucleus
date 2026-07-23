#!/usr/bin/env bash
# Trusts Caddy's locally-managed CA root certificate so that `tls internal`
# reverse proxy targets are recognized without client-side certificate
# warnings. Applies generally to every local reverse proxy using the same
# Caddy PKI authority.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

. "$SCRIPT_DIR/../lib/lib.sh"

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

REPO_ROOT="$(derive_repo_root)"
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

# If we're in sudo mode and Caddy was unreachable, the launchd service may be
# stuck in penalty box (EX_CONFIG). Attempt a fresh bootstrap to recover.
# macOS 26+ SIP blocks unsigned Nix store binaries for system daemons with
# non-root UserName; the /bin/sh wrapper avoids this. See
# .agents/instructions/macos-launchd-sip.instructions.md.
if [ "$_ct_mode" = "sudo" ]; then
  printf '%s\n' "caddy-trust: attempting launchd service recovery via bootout/bootstrap..." >&2
  # check-suppress:suppression_doc: HTTPS proxy service may not be loaded; bootout on absent service exits 1.
  sudo launchctl bootout system/org.nixos.httpsProxy 2>/dev/null || true
  sleep 1
  if sudo launchctl bootstrap system /Library/LaunchDaemons/org.nixos.httpsProxy.plist 2>/dev/null; then
    printf '%s\n' 'caddy-trust: launchd service re-bootstrapped; retrying trust...' >&2
    sleep 2
    _ct_attempt=0
    while [ "$_ct_attempt" -lt 20 ]; do
      if sudo env "PATH=$PATH" caddy trust --address "$_ct_admin_addr"; then
        printf '%s\n' 'caddy-trust: local CA trusted successfully (after service recovery)'
        exit 0
      fi
      _ct_attempt=$((_ct_attempt + 1))
      sleep 1
    done
  fi
fi

printf '%s\n' "caddy-trust: failed to trust local CA from admin endpoint $_ct_admin_addr; continuing without failing apply" >&2
exit 2
