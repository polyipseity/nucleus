#!/usr/bin/env bash
# Full Disk Access (FDA) warning printer function.
#
# Source this file in activation blocks that need FDA access.
# The caller MUST set fda_warning_emitted=0 before the first call.
# print_fda_warning TARGET_DESCRIPTION
# Caller MUST set fda_warning_emitted=0 before the first call.

# Source lib.sh from this library's own directory (callers set SCRIPT_DIR to
# their own location, so resolve relative to this file).
_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$_LIB_DIR/lib.sh"
unset _LIB_DIR

print_fda_warning() {
  local fda_target="$1"
  if [ "$fda_warning_emitted" -eq 1 ]; then
    return
  fi

  # check-suppress:suppression_doc: the FDA banner is advisory output; callers run under `set -e` and must not abort on the non-fatal warning
  error "Full Disk Access Required: Nucleus cannot write $fda_target from this terminal session." || true
  say "To fix this:"
  say "  1. Open System Settings > Privacy & Security > Full Disk Access"
  say "  2. Toggle On for your terminal emulator"
  say "  3. If already enabled, remove and re-add it, then restart the terminal"

  fda_warning_emitted=1
}
