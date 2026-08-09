#!/usr/bin/env bash
# Wait for sops-nix to materialize secrets before proceeding with identity setup.
# Exits with an error if the sentinel secret hasn't appeared within the deadline.

set -euo pipefail

_wss_sentinel="$1"
_wss_deadline=30
_wss_waited=0
while [ ! -s "$_wss_sentinel" ] && [ "$_wss_waited" -lt "$_wss_deadline" ]; do
  sleep 1
  _wss_waited=$((_wss_waited + 1))
done
if [ ! -s "$_wss_sentinel" ]; then
  echo "waitForSopsSecrets: timed out after 30 s waiting for sops-nix to materialize secrets; sops-install-secrets may have failed or /etc/sops/age/machine.txt may be absent." >&2
  exit 1
fi
