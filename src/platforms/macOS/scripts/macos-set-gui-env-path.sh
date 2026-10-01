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

# WHY: compose PATH from non-empty fragments only. Prepend, cleaned, and append can each be
# empty, and a guard expression cannot join non-empty segments with a single colon: when
# prepend AND cleaned are both empty, the append guard's leading colon survives and the PATH
# starts with an empty entry (= cwd).
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

# All other GUI env vars, user and non-user.
eval "$_mge_all_vars_block"

# NUCLEUS_REPO_ROOT, from the system repo-root file.
# WHY: NUCLEUS_REPO_ROOT left the env catalog to prevent Nix store path poisoning, but some
# scripts still read it directly. Set it from the authoritative system repo-root file so GUI
# processes see the live checkout path.
_mge_repo_root_file="/Library/Application Support/nucleus/repo-root"
if [ -f "$_mge_repo_root_file" ] && IFS= read -r _mge_repo_root_val <"$_mge_repo_root_file" 2>/dev/null; then
  case "$_mge_repo_root_val" in
  /*) /bin/launchctl setenv NUCLEUS_REPO_ROOT "$_mge_repo_root_val" ;;
  esac
fi

# WHY: user.plist, not system.plist. The PATH holds user-specific directories, and
# LaunchServices .app bundles read the per-user launchd PATH.
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
