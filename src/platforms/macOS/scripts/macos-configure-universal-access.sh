#!/usr/bin/env bash
# Configure Accessibility preferences via defaults.
# These are user/session scoped and applied from user activation to keep
# accessibility intent without system errors.
#
# Requires print_fda_warning function (self-sourced below).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../../scripts/lib/macos-fda-warning.sh"
fda_warning_emitted=0

set_default() {
  domain="$1"
  key="$2"
  value="$3"
  value_type="$4"
  yellow="$(printf '\033[33m')"
  bold="$(printf '\033[1m')"
  reset="$(printf '\033[0m')"

  if ! write_err="$({ /usr/bin/defaults write "$domain" "$key" "-$value_type" "$value"; } 2>&1)"; then
    if printf '%s' "$write_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
      print_fda_warning "Accessibility preferences"
      printf '%s![Permission Denied]%s Failed to set %s%s %s%s. Ensure Full Disk Access and Accessibility permissions are granted.\n' "$yellow" "$reset" "$bold" "$domain" "$key" "$reset" >&2
    else
      echo "macos: failed to set $domain $key ($write_err)." >&2
    fi
  fi
}

# Source: macOS Accessibility preference settings.
# https://support.apple.com/en-us/guide/mac-help/accessibility-settings-on-mac-mh40584/mac
set_default "com.apple.universalaccess" "FontSizeCategory" "AX1" "string"
set_default "com.apple.universalaccess" "cursorSize" "1.33" "float"
set_default "com.apple.universalaccess" "reduceMotion" "false" "bool"
set_default "com.apple.universalaccess" "reduceTransparency" "false" "bool"
set_default "com.apple.universalaccess" "showWindowTitlebarIcons" "true" "bool"
