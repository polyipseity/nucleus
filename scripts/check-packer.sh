#!/usr/bin/env bash
# Checks .pkr.hcl files under src/vms/. With arguments, checks only provided paths.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

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
# Each template may require different -var flags for required variables.
validate_dir() {
  local dir="$1"
  printf 'Validating %s...\n' "$dir"
  local vars=()
  case "$dir" in
    *nixos)
      vars=(-var guest_username=dummy -var guest_password=dummy -var nixos_iso_url=https://dummy.iso -var nixos_iso_checksum=none)
      ;;
    *windows)
      vars=(-var windows_iso=dummy.iso)
      ;;
    *macos)
      vars=(-var macos_version=14.0 -var vm_name=dummy -var cpus=2 -var memory_gib=4 -var disk_size_gib=40 -var guest_username=dummy -var guest_password=dummy -var ssh_username=dummy -var ssh_password=dummy -var tart_image_ref=dummy)
      ;;
  esac
  (cd "$dir" && packer init . && packer validate "${vars[@]}" .)
}

validate_dir src/vms/nixos
validate_dir src/vms/windows

# macOS template uses the Tart plugin which is macOS-only.
if [ "$(uname)" = "Darwin" ]; then
  validate_dir src/vms/macos
else
  printf 'Skipping macOS Packer template validation (requires Tart plugin on macOS)\n'
fi
