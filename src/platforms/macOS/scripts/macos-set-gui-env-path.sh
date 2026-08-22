#!/usr/bin/env bash
# Propagate NUCLEUS_REPO_ROOT to the GUI launchd domain.
# Set during activation; the gui-env LaunchAgent covers login-time before first activation.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

_mge_prepend="$1"
_mge_append="$2"
_mge_managed_set="$3"
_mge_all_vars_block="$4"
_mge_launchctl_config_path="$5"

if [ -n "${NUCLEUS_REPO_ROOT:-}" ]; then
  /bin/launchctl setenv NUCLEUS_REPO_ROOT "$NUCLEUS_REPO_ROOT"
fi

# Strip stale managed entries from launchctl PATH, then prepend + append
# managed dirs for the GUI launchd domain.

CURRENT_PATH="$(/bin/launchctl getenv PATH 2>/dev/null || true)" # check-suppress:suppression_doc: launchctl may not be available (early boot, non-GUI session); fall back to $PATH
if [ -z "$CURRENT_PATH" ]; then
  CURRENT_PATH="$PATH"
fi

_mge_cleaned=""
old_IFS="$IFS"
IFS=:
for __component in $CURRENT_PATH; do
  case ":${_mge_managed_set}:" in
  *":${__component}:"*) ;;
  *)
    _mge_cleaned="${_mge_cleaned:+${_mge_cleaned}:}${__component}"
    ;;
  esac
done
IFS="$old_IFS"

# Compose PATH from non-empty fragments only (prepend may be empty, cleaned
# may be empty when every PATH entry is managed, append may be empty).  A
# guard expression cannot express "join non-empty segments with a single
# colon": when prepend AND cleaned are both empty, the append guard's leading
# colon survives and the PATH starts with an empty entry (= cwd).
_mge_path=""
for _mge_frag in "$_mge_prepend" "$_mge_cleaned" "$_mge_append"; do
  [ -n "$_mge_frag" ] || continue
  if [ -n "$_mge_path" ]; then
    _mge_path="${_mge_path}:${_mge_frag}"
  else
    _mge_path="$_mge_frag"
  fi
done
/bin/launchctl setenv PATH "$_mge_path"

# ── All other GUI env vars (user and non-user) ──
eval "$_mge_all_vars_block"

# Set persistent per-user launchd PATH for LaunchServices .app bundles.
# Uses user.plist (not system.plist) because the PATH contains user-specific
# directories.
_mge_desired_path="$_mge_launchctl_config_path"
_mge_current_path="$(/usr/libexec/PlistBuddy -c 'Print PathEnvironmentVariable' /private/var/db/com.apple.xpc.launchd/config/user.plist 2>/dev/null || true)" # check-suppress:suppression_doc: user.plist may not exist before first launchctl config write; read fails gracefully

if [ "$_mge_current_path" != "$_mge_desired_path" ]; then
  say -l launchd "updating user PATH (current differs from desired)."
  if /usr/bin/sudo /bin/launchctl config user path "$_mge_desired_path" 2>/dev/null; then
    say -l launchd "user PATH updated via launchctl config user path."
    say -l launchd "REBOOT REQUIRED for .app bundles to inherit the new PATH."
  else
    die -l launchd "failed to update user PATH."
  fi
else
  say -l launchd "user PATH already up-to-date."
fi
