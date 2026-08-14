#!/usr/bin/env bash
# Wait for sops-nix to materialize secrets before proceeding with identity setup.
# Exits with an error if the sentinel secret hasn't appeared within the deadline.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_wss_sentinel="$1"
_wss_deadline=30
_wss_waited=0
while [ ! -s "$_wss_sentinel" ] && [ "$_wss_waited" -lt "$_wss_deadline" ]; do
  sleep 1
  _wss_waited=$((_wss_waited + 1))
done
if [ ! -s "$_wss_sentinel" ]; then
  die -l waitForSopsSecrets "timed out after 30 s waiting for sops-nix to materialize secrets; sops-install-secrets may have failed or /etc/sops/age/machine.txt may be absent."
fi
