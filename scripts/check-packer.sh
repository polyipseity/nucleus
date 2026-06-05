#!/usr/bin/env bash
# check-packer.sh — Validate Packer template formatting and configuration.
#
# With no arguments, checks all .pkr.hcl files under src/vms/. With arguments,
# checks only the provided paths.
#
# Arguments:
#   (none)        No flags accepted; paths may be provided as positional arguments.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any Packer format or validation failure.
set -euo pipefail

# Source shared library when available; fall back to inline helpers for
# standalone execution (e.g. Nix pre-commit hooks where the script is
# copied to a flat store path).
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/../src/scripts/lib.sh" ]; then
  . "$SCRIPT_DIR/../src/scripts/lib.sh"
else
  # inline usage_std — emit standardized usage text
  usage_std() {
    printf 'usage: %s %s\n' "$1" "${2:-}"
    [ "$#" -gt 2 ] && printf '  %s\n' "$3"
  }
  # inline resolve_nucleus_root
  resolve_nucleus_root() {
    [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ] && { printf '%s\n' "$NUCLEUS_REPO_ROOT"; return 0; }
    printf '%s\n' "${HOME}/dev/nucleus"
  }
fi

REPO_ROOT=$(resolve_nucleus_root)
cd "$REPO_ROOT"

usage() {
  usage_std "check-packer.sh" "[path ...]" "Validate Packer template formatting and configuration. With no arguments, checks all .pkr.hcl files under src/vms/. With arguments, checks only the provided paths."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf '%s\n' "error: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
  shift
done

# Check formatting
if [ "$#" -gt 0 ]; then
  packer fmt -check "$@"
else
  packer fmt -check -recursive src/vms/
fi

# Validate each Packer template in its own directory (needed for plugin
# resolution and relative path references).
validate_dir() {
  local dir="$1"
  printf 'Validating %s...\n' "$dir"
  (cd "$dir" && packer init . && packer validate .)
}

validate_dir src/vms/nixos
validate_dir src/vms/windows

# macOS template uses the Tart plugin which is macOS-only.
if [ "$(uname)" = "Darwin" ]; then
  validate_dir src/vms/macos
else
  printf 'Skipping macOS Packer template validation (requires Tart plugin on macOS)\n'
fi
