#!/usr/bin/env bash
# Checks .pkr.hcl files under src/vms/. With arguments, checks only provided paths.
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

REPO_ROOT=$(derive_repo_root)
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
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
  shift
done

require_command packer
require_command jq

# Share plugin cache across Packer invocations to avoid re-downloading plugins.
# This is the recommended pattern per Packer docs:
# https://developer.hashicorp.com/packer/docs/plugins#plugin-cache
export PACKER_PLUGIN_CACHE_DIR="${PACKER_PLUGIN_CACHE_DIR:-$HOME/.cache/packer/plugins}"

# Determine system architecture for reading the NixOS ISO checksum from lockfile.
# Lockfile uses nixpkgo-style arch names: x86_64-linux, aarch64-linux.
_arch="$(uname -m)"
case "$_arch" in
  x86_64) _nix_arch="x86_64-linux" ;;
  arm64|aarch64) _nix_arch="aarch64-linux" ;;
  *)
    error "unsupported architecture '$_arch' for NixOS ISO checksum lookup"
    exit 1
    ;;
esac

# Read NixOS ISO digest from lockfile for the current arch.
_nixos_digest="$(jq -r --arg arch "$_nix_arch" '(."vm-setup"."nixos-iso" // {})[$arch].digest // "none"' "$REPO_ROOT/src/lockfiles/lockfile.json")"

# Check formatting
if [ "$#" -gt 0 ]; then
  packer fmt -check "$@"
else
  packer fmt -check -recursive src/vms/
fi

# Validate each Packer template in its own directory (needed for plugin
# resolution and relative path references).
# Each template may require different -var flags for required variables.
#
# Filter the known checksum-none warning (windows template only). WHY:
# Microsoft publishes no stable Windows 11 ISO checksums, so
# src/vms/windows/packer.pkr.hcl intentionally sets iso_checksum to "none"
# (see the variable description at line 39 and check-suppress comment at
# line 228). The packer validate exit code below is still enforced — only
# the expected warning text is hidden.
_filter_known_packer_warnings() {
  awk '
    /Warning: A checksum of .none. was specified/ { skip=1 }
    skip && /\(source code not available\)/ { skip=0; next }
    !skip { print }
  '
}

validate_dir() {
  local dir="$1"
  say "validating $dir..."
  local vars=()
  case "$dir" in
    *nixos)
      vars=(-var guest_username=dummy -var guest_password=dummy -var nixos_iso_url=https://dummy.iso -var "nixos_iso_checksum=$_nixos_digest")
      ;;
    *windows)
      vars=(-var windows_iso=dummy.iso)
      ;;
    *macos)
      vars=(-var macos_version=14.0 -var vm_name=dummy -var cpus=2 -var memory_gib=4 -var disk_size_gib=40 -var guest_username=dummy -var guest_password=dummy -var ssh_username=dummy -var ssh_password=dummy -var tart_image_ref=dummy)
      ;;
  esac
  # 2>&1 into the filter: the warning goes to stderr; pipefail keeps the
  # packer validate exit code authoritative.
  (cd "$dir" && packer init . && packer validate "${vars[@]}" . 2>&1 | _filter_known_packer_warnings)
}

# Parallel validation: each VM directory validates independently.
# Uses temp exit files for race-free aggregation (same pattern as check.sh).
_pkr_tmpdir=$(mktemp -d) || { error "failed to create temp directory for packer validation"; exit 1; }

{ _vd_exit=0; validate_dir src/vms/nixos || _vd_exit=$?; echo "$_vd_exit" > "$_pkr_tmpdir/exit-nixos"; } &
{ _vd_exit=0; validate_dir src/vms/windows || _vd_exit=$?; echo "$_vd_exit" > "$_pkr_tmpdir/exit-windows"; } &

# macOS template uses the Tart plugin which is macOS-only.
if [ "$(uname)" = "Darwin" ]; then
  { _vd_exit=0; validate_dir src/vms/macos || _vd_exit=$?; echo "$_vd_exit" > "$_pkr_tmpdir/exit-macos"; } &
else
  say "skipping macOS Packer template validation (requires Tart plugin on macOS)"
fi

wait

_pkr_exit=0
for _pkr_ef in "$_pkr_tmpdir"/exit-*; do
  [ -f "$_pkr_ef" ] || continue
  read -r _pkr_code < "$_pkr_ef"
  [ "$_pkr_code" != "0" ] && _pkr_exit=$((_pkr_exit + 1))
done

rm -rf -- "$_pkr_tmpdir"

if [ "$_pkr_exit" -gt 0 ]; then
  error "Packer validation failed with $_pkr_exit error(s)"
  exit 1
fi
