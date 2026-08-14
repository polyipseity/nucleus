#!/usr/bin/env bash
# Preflight macOS privacy permissions before defaults writes.
# Full Disk Access privacy preflight. Runs FDA checks before defaults writes.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
. "$SCRIPT_DIR/../../../scripts/lib/macos-fda-warning.sh"

_pp_repo_root="$1"

say "checking macOS privacy permissions before defaults writes..."

fda_warning_emitted=0

probe_domain="com.apple.universalaccess"
probe_key="NucleusActivationProbe"
if ! probe_err="$({
  /usr/bin/defaults write "$probe_domain" "$probe_key" -bool false
  /usr/bin/defaults delete "$probe_domain" "$probe_key"
} 2>&1)"; then
  if printf '%s' "$probe_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
    print_fda_warning "protected user preferences"
  else
    warn "privacy preflight probe failed unexpectedly ($probe_err); continuing with best-effort defaults writes."
  fi
fi
