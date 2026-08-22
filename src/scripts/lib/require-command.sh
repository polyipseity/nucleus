# shellcheck shell=bash
# require_command for CamillaDSP service scripts. Sourced by
# camilladsp-run.sh and camilladsp-heartbeat.sh; the heartbeat does not
# source lib.sh itself, so lib.sh is resolved from this file's directory.

# Source lib.sh from this library's own directory (callers set SCRIPT_DIR to
# their own location, so resolve relative to this file).
_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$_LIB_DIR/lib.sh"
unset _LIB_DIR

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 is required but was not found in PATH"
  fi
}
