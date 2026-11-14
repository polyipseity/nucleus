#!/usr/bin/env bash
# shellcheck shell=bash
# ensure-rip-graveyard.sh - create the rip graveyard under the nucleus USER root.
#
# rip reads RIP_GRAVEYARD from the environment (src/modules/lib/env-secrets.nix),
# which an activation, a cron job, or sudo does not necessarily carry. The
# directory is created here so the first deletion from such a process lands in
# the managed root instead of rip's per-session $TMPDIR default.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_erg_graveyard="$NUCLEUS_USER_ROOT/state/rip/graveyard"

if [ ! -d "$_erg_graveyard" ]; then
  mkdir -p "$_erg_graveyard"
  notice "created rip graveyard: $_erg_graveyard"
fi
