#!/usr/bin/env bash
# Reset service health: delete all health records at apply-time.
# The watchdog recreates records on-demand via svc_health_init, so
# wiping stale state is safe and avoids cross-boot residue.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/service-health.sh
. "$SCRIPT_DIR/../lib/service-health.sh"

_state_dir="$(svc_health_state_dir)"
[ -d "$_state_dir" ] || exit 0

# check-suppress:suppression_doc: intentional full reset of service health state at apply-time
find "$_state_dir" -maxdepth 1 -name '*.json' -delete 2>/dev/null || true
