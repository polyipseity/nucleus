# shellcheck shell=sh
# Shared console user/UID resolution for macOS activation scripts. Source this
# file (or inline it via Nix) in activation contexts that must run privileged
# commands as the console session's user.
#
# WHY: the UID comes from stat(1) on /dev/console rather than from id(1) on the
# username, so every caller resolves it the same way regardless of ordering.
#
# _nucleus_resolve_console_user fills $_nucleus_console_uid and
# $_nucleus_console_user, and returns 1 when /dev/console is inaccessible
# (headless or SSH session), empty, or owned by root.

_nucleus_resolve_console_user() {
  _nucleus_console_uid="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || true)"   # check-suppress:suppression_doc: /dev/console inaccessible in headless/SSH session; handled by the empty check below
  _nucleus_console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)" # check-suppress:suppression_doc: /dev/console inaccessible in headless/SSH session; handled by the empty check below

  if [ -z "$_nucleus_console_uid" ] || [ "$_nucleus_console_uid" = "0" ]; then
    return 1
  fi
  return 0
}
