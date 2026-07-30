# shellcheck shell=sh
#
# Shared console user/UID resolution for macOS activation scripts.
# Source this file (or inline via Nix) in activation script contexts
# that need to resolve the current console session's user and run
# privileged commands as that user.
#
# The function reads /dev/console directly via stat(1) rather than
# deriving the UID from the username with id(1), making each caller
# independent of activation ordering.
#
# Provides:
#   _nucleus_resolve_console_user  — resolve console user into globals
#   $_nucleus_console_uid          — numeric UID, e.g. 501
#   $_nucleus_console_user         — short username, e.g. "jane"
#
# Returns 0 on success.  Returns 1 when /dev/console is inaccessible
# (headless/SSH session), empty, or the UID is 0 (root session).

_nucleus_resolve_console_user() {
  _nucleus_console_uid="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || true)" # check-suppress:suppression_doc: /dev/console inaccessible in headless/SSH session; handled by the empty check below
  _nucleus_console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)" # check-suppress:suppression_doc: /dev/console inaccessible in headless/SSH session; handled by the empty check below

  if [ -z "$_nucleus_console_uid" ] || [ "$_nucleus_console_uid" = "0" ]; then
    return 1
  fi
  return 0
}
