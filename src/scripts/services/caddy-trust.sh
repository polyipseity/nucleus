#!/usr/bin/env bash
# Trust Caddy's locally-managed CA root so `tls internal` targets are
# recognized without client-side certificate warnings. Any local reverse proxy
# on the same Caddy PKI authority benefits.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/macos-launch-services.sh
. "$SCRIPT_DIR/../lib/macos-launch-services.sh"

usage() {
  usage_std "$(basename "$0")" "{sudo|user}" "Trust the Caddy CA certificate for the current user or system-wide."
  cat <<'EOF'
  -h, --help    Show this help message and exit
EOF
}

case "${1:-}" in
-h | --help)
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
  say -l caddy-trust 'caddy not found in PATH; skipping local CA trust'
  exit 1
fi

REPO_ROOT="$(derive_repo_root)"
_ct_admin_addr="$(jq -r '.caddy.network.admin | "\(.host):\(.port)"' "$REPO_ROOT/src/modules/services.json" 2>/dev/null || echo '127.0.0.1:2019')"

_ct_attempt=0
while [ "$_ct_attempt" -lt 20 ]; do
  if [ "$_ct_mode" = "sudo" ]; then
    if sudo env "PATH=$PATH" caddy trust --address "$_ct_admin_addr"; then
      say -l caddy-trust 'local CA trusted successfully'
      exit 0
    fi
  else
    if caddy trust --address "$_ct_admin_addr"; then
      say -l caddy-trust 'local CA trusted successfully'
      exit 0
    fi
  fi

  _ct_attempt=$((_ct_attempt + 1))
  sleep 1
done

# WHY: an unreachable Caddy in sudo mode can mean the launchd service sits in
# the penalty box (EX_CONFIG). A fresh bootstrap recovers it. See
# macos-service-hardening.instructions.md for the macOS 26+ SIP case.
if [ "$_ct_mode" = "sudo" ]; then
  warn -l caddy-trust "attempting launchd service recovery via bootout/bootstrap..."
  _ct_proxy_target=system/org.nixos.httpsProxy
  _ct_proxy_plist=/Library/LaunchDaemons/org.nixos.httpsProxy.plist
  # WHY: macOS 26+ unloads asynchronously, so a bootstrap issued before the
  #   unload finishes fails with "Bootstrap failed: 5:" and the proxy stays
  #   unloaded.
  _ct_reload_out=""
  if launchctl_bootout_wait "$_ct_proxy_target" sudo &&
    _ct_reload_out=$(launchctl_bootstrap_plist system "$_ct_proxy_plist" "$_ct_proxy_target" sudo); then
    warn -l caddy-trust 'launchd service re-bootstrapped; retrying trust...'
    sleep 2
    _ct_attempt=0
    while [ "$_ct_attempt" -lt 20 ]; do
      if sudo env "PATH=$PATH" caddy trust --address "$_ct_admin_addr"; then
        say -l caddy-trust 'local CA trusted successfully (after service recovery)'
        exit 0
      fi
      _ct_attempt=$((_ct_attempt + 1))
      sleep 1
    done
  else
    _ct_reload_reason="${_ct_reload_out:-launchctl bootout did not unload $_ct_proxy_target}"
    # check-suppress:suppression_doc: the trust attempt is best-effort by design; the final warning below reports the failed apply step.
    error -l caddy-trust "HTTPS proxy service could not be reloaded: $_ct_reload_reason" || true
  fi
fi

warn -l caddy-trust "failed to trust local CA from admin endpoint $_ct_admin_addr; continuing without failing apply"
exit 2
