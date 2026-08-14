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

  printf '%s%sERROR: Full Disk Access Required%s\n' "$_nuc_c2_red" "$_nuc_c2_bold" "$_nuc_c2_reset" >&2
  printf '%sNucleus cannot write %s from this terminal session.%s\n' "$_nuc_c2_yellow" "$fda_target" "$_nuc_c2_reset" >&2
  printf '%s\n' "To fix this:" >&2
  printf '  1. Open %sSystem Settings > Privacy & Security > Full Disk Access%s\n' "$_nuc_c2_bold" "$_nuc_c2_reset" >&2
  printf '  2. Toggle %sOn%s for your terminal emulator\n' "$_nuc_c2_bold" "$_nuc_c2_reset" >&2
  printf '  3. If already enabled, remove and re-add it, then restart the terminal\n' >&2

  fda_warning_emitted=1
}
