# shellcheck shell=sh
# Minimal helpers for CamillaDSP service scripts — avoids lib.sh dependency.
# Prepended at build time by the Nix packaging (camilladsp.nix).

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: $1 is required but was not found in PATH" >&2
    exit 1
  fi
}
