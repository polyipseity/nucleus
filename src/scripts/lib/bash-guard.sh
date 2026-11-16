# shellcheck shell=bash
# Shared bash version guard for nucleus POSIX entrypoints.
#
# Source this after SCRIPT_DIR is computed and before any construct that needs a
# newer bash than the declared minimum. This file must parse under bash 3.2 so
# bootstrap.sh can source it on stock macOS bash.
#
# Usage:
#   # shellcheck source=../src/scripts/lib/bash-guard.sh
#   . "$SCRIPT_DIR/../src/scripts/lib/bash-guard.sh"
#   bash_guard_require 5 1 check

bash_guard_require() {
  local _bg_min_major _bg_min_minor _bg_name
  local _bg_have_major _bg_have_minor _bg_have

  _bg_min_major="${1:-0}"
  _bg_min_minor="${2:-0}"
  _bg_name="${3:-script}"
  _bg_have_major="${BASH_VERSINFO[0]:-0}"
  _bg_have_minor="${BASH_VERSINFO[1]:-0}"
  _bg_have="${BASH_VERSION:-unknown}"

  if [ "$_bg_have_major" -gt "$_bg_min_major" ]; then
    return 0
  fi
  if [ "$_bg_have_major" -eq "$_bg_min_major" ] && [ "$_bg_have_minor" -ge "$_bg_min_minor" ]; then
    return 0
  fi

  printf '%s\n' "error: ${_bg_name} requires bash >= ${_bg_min_major}.${_bg_min_minor}, but this shell is ${_bg_have}." >&2
  printf '%s\n' "hint: rerun with a compatible bash, for example:" >&2
  printf '%s\n' "  nix run ./src#${_bg_name}" >&2
  # shellcheck disable=SC2016 # reason: show literal $USER/$PATH in copy-pastable remediation
  printf '%s\n' "  PATH=\"/etc/profiles/per-user/\$USER/bin:/run/current-system/sw/bin:\$PATH\" /run/current-system/sw/bin/bash ./scripts/${_bg_name}.sh" >&2
  exit 1
}

bash_guard_assert() {
  bash_guard_require "$@"
}
