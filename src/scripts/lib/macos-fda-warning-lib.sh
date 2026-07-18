# shellcheck shell=sh
# Full Disk Access (FDA) warning printer function.
#
# Source this file in activation blocks that need FDA access.
# The caller MUST set fda_warning_emitted=0 before the first call.
# Token __FDA_TARGET__ describes the operation needing FDA.

print_fda_warning() {
  if [ "$fda_warning_emitted" -eq 1 ]; then
    return
  fi

  bold="$(printf '\033[1m')"
  red="$(printf '\033[31m')"
  reset="$(printf '\033[0m')"
  yellow="$(printf '\033[33m')"

  printf '%s%sERROR: Full Disk Access Required%s\n' "$red" "$bold" "$reset" >&2
  printf '%sNucleus cannot write __FDA_TARGET__ from this terminal session.%s\n' "$yellow" "$reset" >&2
  printf '%s\n' "To fix this:" >&2
  printf '  1. Open %sSystem Settings > Privacy & Security > Full Disk Access%s\n' "$bold" "$reset" >&2
  printf '  2. Toggle %sOn%s for your terminal emulator\n' "$bold" "$reset" >&2
  printf '  3. If already enabled, remove and re-add it, then restart the terminal\n' >&2

  fda_warning_emitted=1
}
