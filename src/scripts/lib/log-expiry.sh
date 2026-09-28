# shellcheck shell=bash
# Log-retention resolver for nucleus hosts.
#
# Source from entry-point scripts and service scripts.
#
# Environment variables:
#   NUCLEUS_LOG_EXPIRY  Log retention duration (optional, defaults to 7d).
#
# WHY: log retention is a logging concern. It used to read NUCLEUS_GC_EXPIRY,
# a Nix GC knob set from modules.gc.expiry, so raising GC retention silently
# raised log retention. One resolver, one variable, so the two cannot drift
# apart again.

resolve_log_expiry() {
  printf '%s' "${NUCLEUS_LOG_EXPIRY:-7d}"
}
