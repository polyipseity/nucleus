#!/usr/bin/env bash
# Configure Safari preferences via defaults.
# These are applied from user activation because Safari is sandboxed and stores
# preferences in a containerized domain.
#
# Requires print_fda_warning function (self-sourced below).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
. "$SCRIPT_DIR/../../../scripts/lib/macos-fda-warning.sh"
fda_warning_emitted=0

set_safari_default() {
  key="$1"
  value="$2"
  value_type="$3"

  if ! write_err="$({ /usr/bin/defaults write com.apple.Safari "$key" "-$value_type" "$value"; } 2>&1)"; then
    if printf '%s' "$write_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
      print_fda_warning "protected Safari preferences"
      die "failed to set Safari key $key due to missing privacy authorization."
    else
      die "failed to set Safari key $key ($write_err)."
    fi
  fi
}

# Source: Safari preference behavior.
# https://support.apple.com/en-us/guide/safari/change-settings-ibrwa005/mac
set_safari_default "AutoFillPasswords" "true" "bool"
set_safari_default "IncludeDevelopMenu" "true" "bool"
set_safari_default "IncludeInternalDebugMenu" "true" "bool"
