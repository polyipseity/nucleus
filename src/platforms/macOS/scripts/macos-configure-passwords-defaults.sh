#!/usr/bin/env bash
# Configure PassKit policy preferences via defaults.
# These are applied from user activation because the PassKit daemon reverts
# writes made during darwin-rebuild switch, so the live user-terminal context
# is required for the values to persist.
#
# Requires print_fda_warning function (self-sourced below).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
. "$SCRIPT_DIR/../../../scripts/lib/macos-fda-warning.sh"
fda_warning_emitted=0

set_passkit_policy_default() {
  key="$1"
  value="$2"
  value_type="$3"

  if ! write_err="$({ /usr/bin/defaults write com.apple.PassKit.policy "$key" "-$value_type" "$value"; } 2>&1)"; then
    if printf '%s' "$write_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
      print_fda_warning "protected PassKit policy preferences"
      die "failed to set PassKit policy key $key due to missing privacy authorization."
    else
      die "failed to set PassKit policy key $key ($write_err)."
    fi
  fi
}

# Source: PassKit password/verification-code autofill policy.
set_passkit_policy_default "AutoFillPasskeysAndPasswords" "1" "bool"
set_passkit_policy_default "AutoFillPasskeysAndPasswordsSource" "com.apple.Passwords" "string"
set_passkit_policy_default "SetupVerificationCodesEnabled" "1" "bool"
set_passkit_policy_default "DeleteVerificationCodesAfterUse" "0" "bool"
