# shellcheck shell=bash
# Log-retention resolver for nucleus hosts. NUCLEUS_LOG_EXPIRY overrides the 7d
# default.
#
# WHY its own variable: retention used to read NUCLEUS_GC_EXPIRY, a Nix GC knob
# set from modules.gc.expiry, so raising GC retention silently raised log
# retention too. One concern, one variable.

resolve_log_expiry() {
  printf '%s' "${NUCLEUS_LOG_EXPIRY:-7d}"
}
