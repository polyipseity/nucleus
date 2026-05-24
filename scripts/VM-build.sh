#!/usr/bin/env sh
# scripts/VM-build.sh — Build pre-built VM disk images consumed by VM-setup.sh.
#
# Produces QCOW2 images at ~/virtual machines/images/<name>.qcow2.
# VM-setup.sh detects these and uses them instead of creating empty disks,
# eliminating the manual OS installation step.
#
# Usage:
#   scripts/VM-build.sh [options]
#
# Options:
#   --dry-run              Print planned actions without executing.
#   --nixos-only           Build only the NixOS guest image.
#   --windows-only         Build only the Windows 11 guest image.
#   --windows-iso PATH     Path to the Windows 11 ISO (required for Windows).
#                          Download: https://www.microsoft.com/software-download/windows11
#   --accelerator TYPE     QEMU accelerator override (hvf/kvm/tcg).
#                          Defaults: hvf on macOS, kvm on Linux.
#
# Prerequisites:
#   NixOS guest  : nix (for nix run github:nix-community/nixos-generators).
#   Windows guest: packer (installed via pkgs.packer), QEMU, Windows 11 ISO.
#
# Run as alias:
#   nucleus-VM-build  (equivalent to scripts/VM-build.sh)
#
# Source: https://github.com/nix-community/nixos-generators
#         https://developer.hashicorp.com/packer/plugins/builders/qemu

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/src/modules/VMs.json"
VMS_DIR="$REPO_ROOT/vms"
IMAGES_DIR="$HOME/virtual machines/images"

dry_run=false
build_nixos=true
build_windows=true
windows_iso=''
accelerator=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)       dry_run=true ;;
    --nixos-only)    build_windows=false ;;
    --windows-only)  build_nixos=false ;;
    --windows-iso)   windows_iso="$2"; shift ;;
    --accelerator)   accelerator="$2"; shift ;;
    *)
      printf 'VM-build: unknown argument: %s\n' "$1" >&2
      printf 'VM-build: usage: %s [--dry-run] [--nixos-only|--windows-only] [--windows-iso PATH] [--accelerator TYPE]\n' "$0" >&2
      exit 1
      ;;
  esac
  shift
done

# Auto-detect QEMU accelerator for this host platform.
if [ -z "$accelerator" ]; then
  case "$(uname -s)" in
    Darwin) accelerator='hvf' ;;
    Linux)  accelerator='kvm' ;;
    *)      accelerator='tcg' ;;
  esac
fi

if [ ! -f "$MANIFEST" ]; then
  printf 'VM-build: manifest not found: %s\n' "$MANIFEST" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'VM-build: jq not found; ensure nixpkgs packages are installed\n' >&2
  exit 1
fi

if [ "$dry_run" = false ]; then
  mkdir -p "$IMAGES_DIR"
fi

# Detect host architecture and choose the nixos-generators format accordingly.
#   aarch64/arm64 → qcow-efi  (UTM on Apple Silicon uses UEFI/virt machine)
#   x86_64/amd64  → qcow      (BIOS mode, matches q35/SeaBIOS on x86_64 hosts)
case "$(uname -m)" in
  aarch64|arm64)
    _nixos_system='aarch64-linux'
    _nixos_format='qcow-efi'
    ;;
  *)
    _nixos_system='x86_64-linux'
    _nixos_format='qcow'
    ;;
esac

# build_nixos_image NAME
#   Builds the NixOS guest image via nixos-generators.  On macOS this
#   cross-compiles to the target Linux architecture using the Nix binary cache.
build_nixos_image() {
  _name="$1"
  _out="$IMAGES_DIR/${_name}.qcow2"

  if [ -f "$_out" ]; then
    printf 'VM-build: NixOS image already exists (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  _guest_nix="$VMS_DIR/nixos/guest.nix"
  if [ ! -f "$_guest_nix" ]; then
    printf 'VM-build: nixos guest config not found: %s\n' "$_guest_nix" >&2
    return 1
  fi

  printf 'VM-build: building NixOS image (system=%s, format=%s)...\n' \
    "$_nixos_system" "$_nixos_format"

  if [ "$dry_run" = true ]; then
    printf 'VM-build: [dry-run] nix run github:nix-community/nixos-generators -- --format %s --system %s --configuration %s -o <tmpdir>\n' \
      "$_nixos_format" "$_nixos_system" "$_guest_nix"
    return 0
  fi

  _tmpdir="$(mktemp -d)"
  nix run github:nix-community/nixos-generators -- \
    --format "$_nixos_format" \
    --system "$_nixos_system" \
    --configuration "$_guest_nix" \
    -o "$_tmpdir"

  # Copy the produced image (follow symlinks so we get the real file, not a
  # nix-store reference that could be garbage-collected).
  _img="$(find "$_tmpdir" -maxdepth 1 -name '*.qcow2' -print -quit 2>/dev/null)"
  if [ -z "$_img" ] || [ ! -e "$_img" ]; then
    printf 'VM-build: nixos-generators produced no .qcow2 in %s\n' "$_tmpdir" >&2
    rm -rf "$_tmpdir"
    return 1
  fi
  # -L follows symlinks so we copy the actual disk image bytes.
  cp -L "$_img" "$_out"
  rm -rf "$_tmpdir"
  printf 'VM-build: NixOS image ready: %s\n' "$_out"
}

# build_windows_image NAME DISK_GIB
#   Builds the Windows 11 guest image using Packer and the Autounattend.xml
#   answer file at vms/windows/Autounattend.xml.
build_windows_image() {
  _name="$1"
  _disk_gib="$2"
  _out="$IMAGES_DIR/${_name}.qcow2"

  if [ -f "$_out" ]; then
    printf 'VM-build: Windows image already exists (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  if [ -z "$windows_iso" ]; then
    printf 'VM-build: --windows-iso PATH is required for Windows builds\n' >&2
    printf 'VM-build: download from: https://www.microsoft.com/software-download/windows11\n' >&2
    return 1
  fi

  if [ ! -f "$windows_iso" ]; then
    printf 'VM-build: Windows ISO not found: %s\n' "$windows_iso" >&2
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    printf 'VM-build: packer not found; install via nixpkgs (pkgs.packer is in baseSharedPackages)\n' >&2
    return 1
  fi

  _packer_dir="$VMS_DIR/windows"
  _tmp_out="$IMAGES_DIR/${_name}-build"

  printf 'VM-build: building Windows 11 image (disk=%s GiB, accelerator=%s)...\n' \
    "$_disk_gib" "$accelerator"

  if [ "$dry_run" = true ]; then
    printf 'VM-build: [dry-run] cd %s && packer build -var windows_iso=%s -var accelerator=%s -var disk_size=%sG -var output_directory=%s .\n' \
      "$_packer_dir" "$windows_iso" "$accelerator" "$_disk_gib" "$_tmp_out"
    return 0
  fi

  (
    cd "$_packer_dir"
    packer init .
    packer build \
      -var "windows_iso=$windows_iso" \
      -var "accelerator=$accelerator" \
      -var "disk_size=${_disk_gib}G" \
      -var "output_directory=$_tmp_out" \
      .
  )

  _built="$_tmp_out/windows.qcow2"
  if [ ! -f "$_built" ]; then
    printf 'VM-build: Packer did not produce %s\n' "$_built" >&2
    return 1
  fi

  mv "$_built" "$_out"
  rm -rf "$_tmp_out"
  printf 'VM-build: Windows 11 image ready: %s\n' "$_out"
}

# Process each VM declared in the manifest.
_count="$(jq '.vms | length' "$MANIFEST")"
_i=0
_any_built=false
while [ "$_i" -lt "$_count" ]; do
  _vm_name="$(jq -r ".vms[$_i].name" "$MANIFEST")"
  _vm_type="$(jq -r ".vms[$_i].type" "$MANIFEST")"
  _vm_disk_gib="$(jq -r ".vms[$_i].diskGiB" "$MANIFEST")"

  case "$_vm_type" in
    nixos)
      if [ "$build_nixos" = true ]; then
        build_nixos_image "$_vm_name"
        _any_built=true
      fi
      ;;
    windows)
      if [ "$build_windows" = true ]; then
        build_windows_image "$_vm_name" "$_vm_disk_gib"
        _any_built=true
      fi
      ;;
    *)
      printf 'VM-build: skipping "%s" (unsupported type: %s)\n' "$_vm_name" "$_vm_type"
      ;;
  esac

  _i=$((_i + 1))
done

if [ "$_any_built" = true ] && [ "$dry_run" = false ]; then
  printf 'VM-build: images at %s\n' "$IMAGES_DIR"
  printf 'VM-build: run nucleus-VM-setup to provision VM bundles using the built images\n'
fi
