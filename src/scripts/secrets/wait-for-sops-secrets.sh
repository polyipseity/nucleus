#!/usr/bin/env bash
# Wait for sops-nix to materialize the given paths (secret files or rendered
# templates) before their consumers read them.
#
# WHY: on macOS sops-nix installs secrets through a LaunchAgent, so an activation
# entry ordered merely `entryAfter [ "sops-nix" ]` does not gate on the files
# landing on disk — the agent is asynchronous and the consumer would read a path
# that does not exist yet.
#
# Existence — not non-emptiness — is the contract: sops-nix writes every declared
# secret unconditionally, and an empty value is legitimate (an operator who has not
# filled the key in yet). A file that never appears means sops-nix did not run at
# all, which is a hard error for a declared consumer.
#
# Usage: wait-for-sops-secrets <path> [<path> ...]
# Env:   NUCLEUS_SOPS_WAIT_SECONDS — deadline in seconds (default 30)
# Exit:  1 when any path is missing after the deadline (the message lists them)
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

if [ "$#" -eq 0 ]; then
  die -l wait-for-sops-secrets "no secret paths given; nothing to wait for"
fi

_wss_deadline="${NUCLEUS_SOPS_WAIT_SECONDS:-30}"
_wss_waited=0
_wss_missing=""
while :; do
  _wss_missing=""
  for _wss_path in "$@"; do
    [ -e "$_wss_path" ] || _wss_missing="$_wss_missing $_wss_path"
  done
  [ -n "$_wss_missing" ] || break
  if [ "$_wss_waited" -ge "$_wss_deadline" ]; then
    die -l wait-for-sops-secrets "timed out after ${_wss_deadline} s waiting for sops-nix to materialize:$_wss_missing — sops-install-secrets may have failed, or the machine age key may be absent."
  fi
  sleep 1
  _wss_waited=$((_wss_waited + 1))
done

say -l wait-for-sops-secrets "materialized $# secret file(s) after ${_wss_waited} s"
