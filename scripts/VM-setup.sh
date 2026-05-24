#!/usr/bin/env sh
# scripts/VM-setup.sh — Build VM images (if needed) and provision VMs.
#
# Combines the former nucleus-VM-build and nucleus-VM-setup into one command.
# Phase 1 builds pre-built QCOW2 OS images (if absent) using
# nixos-generators (NixOS guest on macOS/NixOS) or Packer (Windows).
# Phase 2 provisions VM bundles/domains from those images.
#
# Usage:
#   scripts/VM-setup.sh [options]
#
# Options:
#   --dry-run              Print planned actions without executing.
#   --nixos-only           Build and provision only the NixOS guest.
#   --windows-only         Build and provision only the Windows 11 guest.
#   --windows-iso PATH     Path to the Windows 11 ISO (required for Windows
#                          guest builds). Download from:
#                          https://www.microsoft.com/software-download/windows11
#   --accelerator TYPE     QEMU accelerator for image builds (hvf/kvm/tcg).
#                          Defaults: hvf on macOS, kvm on Linux.
#
# Environment variables:
#   VM_DIR_OVERRIDE  override the default ~/virtual machines path
#
# Prerequisites:
#   NixOS guest  : nix (for nix run github:nix-community/nixos-generators).
#   Windows guest: packer (installed via pkgs.packer), QEMU, Windows 11 ISO.
#   macOS        : UTM installed (/Applications/UTM.app); qemu-img in PATH.
#   NixOS        : libvirtd enabled (VMs.nix); qemu-img and virsh in PATH.
#
# Exit: always 0 (best-effort — a VM setup failure does not roll back a
#       completed system apply).
#
# Run as alias:
#   nucleus-VM-setup  (equivalent to scripts/VM-setup.sh)
#
# Source: https://github.com/nix-community/nixos-generators
#         https://developer.hashicorp.com/packer/plugins/builders/qemu

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/src/modules/VMs.json"
VMS_DIR="$REPO_ROOT/vms"

dry_run=false
nixos_only=false
windows_only=false
windows_iso=''
accelerator=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)      dry_run=true ;;
    --nixos-only)   nixos_only=true ;;
    --windows-only) windows_only=true ;;
    --windows-iso)  windows_iso="$2"; shift ;;
    --accelerator)  accelerator="$2"; shift ;;
    *)
      printf 'VM-setup: unknown argument: %s\n' "$1" >&2
      printf 'VM-setup: usage: %s [--dry-run] [--nixos-only|--windows-only] [--windows-iso PATH] [--accelerator TYPE]\n' "$0" >&2
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
  printf 'VM-setup: manifest not found at %s; skipping\n' "$MANIFEST" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'VM-setup: jq not found in PATH; cannot parse manifest\n' >&2
  exit 0
fi

VM_DIR="${VM_DIR_OVERRIDE:-$HOME/virtual machines}"
IMAGES_DIR="$VM_DIR/images"

# should_include TYPE — returns 0 if a VM of the given type should be processed.
should_include() {
  _type="$1"
  if [ "$nixos_only" = true ] && [ "$_type" != "nixos" ]; then
    return 1
  fi
  if [ "$windows_only" = true ] && [ "$_type" != "windows" ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_cmd() {
  if [ "$dry_run" = true ]; then
    printf 'VM-setup: [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Phase 1 — Build images (if absent)
# ---------------------------------------------------------------------------

# Detect host architecture for nixos-generators format selection.
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
    printf 'VM-setup: NixOS image already built (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  _guest_nix="$VMS_DIR/nixos/guest.nix"
  if [ ! -f "$_guest_nix" ]; then
    printf 'VM-setup: nixos guest config not found: %s\n' "$_guest_nix" >&2
    return 1
  fi

  printf 'VM-setup: building NixOS image (system=%s, format=%s)...\n' \
    "$_nixos_system" "$_nixos_format"

  if [ "$dry_run" = true ]; then
    printf 'VM-setup: [dry-run] nix run github:nix-community/nixos-generators -- --format %s --system %s --configuration %s -o <tmpdir>\n' \
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
    printf 'VM-setup: nixos-generators produced no .qcow2 in %s\n' "$_tmpdir" >&2
    rm -rf "$_tmpdir"
    return 1
  fi
  # -L follows symlinks so we copy the actual disk image bytes.
  cp -L "$_img" "$_out"
  rm -rf "$_tmpdir"
  printf 'VM-setup: NixOS image ready: %s\n' "$_out"
}

# build_windows_image NAME DISK_GIB
#   Builds the Windows 11 guest image using Packer and the Autounattend.xml
#   answer file at vms/windows/Autounattend.xml.
build_windows_image() {
  _name="$1"
  _disk_gib="$2"
  _out="$IMAGES_DIR/${_name}.qcow2"

  if [ -f "$_out" ]; then
    printf 'VM-setup: Windows image already built (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  if [ -z "$windows_iso" ]; then
    printf 'VM-setup: --windows-iso PATH is required for Windows 11 builds\n' >&2
    printf 'VM-setup: download from: https://www.microsoft.com/software-download/windows11\n' >&2
    return 1
  fi

  if [ ! -f "$windows_iso" ]; then
    printf 'VM-setup: Windows ISO not found: %s\n' "$windows_iso" >&2
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    printf 'VM-setup: packer not found; install via nixpkgs (pkgs.packer is in baseSharedPackages)\n' >&2
    return 1
  fi

  _packer_dir="$VMS_DIR/windows"
  _tmp_out="$IMAGES_DIR/${_name}-build"

  printf 'VM-setup: building Windows 11 image (disk=%s GiB, accelerator=%s)...\n' \
    "$_disk_gib" "$accelerator"

  if [ "$dry_run" = true ]; then
    printf 'VM-setup: [dry-run] cd %s && packer build -var windows_iso=%s -var accelerator=%s -var disk_size=%sG -var output_directory=%s .\n' \
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
    printf 'VM-setup: Packer did not produce %s\n' "$_built" >&2
    return 1
  fi

  mv "$_built" "$_out"
  rm -rf "$_tmp_out"
  printf 'VM-setup: Windows 11 image ready: %s\n' "$_out"
}

build_images() {
  _count="$(jq '.vms | length' "$MANIFEST")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _vm_name="$(jq -r ".vms[$_i].name" "$MANIFEST")"
    _vm_type="$(jq -r ".vms[$_i].type" "$MANIFEST")"
    _vm_disk_gib="$(jq -r ".vms[$_i].diskGiB" "$MANIFEST")"

    if should_include "$_vm_type"; then
      case "$_vm_type" in
        nixos)   build_nixos_image "$_vm_name" ;;
        windows) build_windows_image "$_vm_name" "$_vm_disk_gib" ;;
        *)
          printf 'VM-setup: skipping build for "%s" (unsupported type: %s)\n' \
            "$_vm_name" "$_vm_type"
          ;;
      esac
    fi

    _i=$((_i + 1))
  done
}

write_configure_script() {
  # Generate a reference script documenting how to apply the nucleus host
  # configuration inside the named VM guest.
  _wcs_name="$1"
  _wcs_type="$2"
  _wcs_script="$VM_DIR/${_wcs_name}-configure.sh"
  case "$_wcs_type" in
    nixos)
      cat > "$_wcs_script" << 'CFGEOF'
#!/usr/bin/env sh
# Apply the nucleus nixos host configuration inside this VM.
# ~/dev is shared via VirtioFS when shareDevDir=true.
sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#nixos"
CFGEOF
      ;;
    windows)
      cat > "$_wcs_script" << 'CFGEOF'
#!/usr/bin/env sh
# Apply the nucleus Windows host configuration inside this VM.
# Clone this repository to %USERPROFILE%\dev\nucleus inside the VM, then run:
#   .\src\hosts\windows\apply.ps1
CFGEOF
      ;;
    macos)
      cat > "$_wcs_script" << 'CFGEOF'
#!/usr/bin/env sh
# Apply the nucleus macbook host configuration inside this VM.
# Clone this repository to ~/dev/nucleus inside the VM, then run:
#   ~/dev/nucleus/scripts/bootstrap.sh apply
CFGEOF
      ;;
    *)
      return
      ;;
  esac
  chmod +x "$_wcs_script"
  printf 'VM-setup: wrote configure script: %s\n' "$_wcs_script"
}

# ---------------------------------------------------------------------------
# macOS / UTM
# ---------------------------------------------------------------------------

setup_utm_vms() {
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

  if [ ! -d /Applications/UTM.app ]; then
    printf 'VM-setup: UTM not found at /Applications/UTM.app; skipping macOS VM provisioning\n'
    return
  fi

  if [ ! -x "$UTMCTL" ]; then
    printf 'VM-setup: utmctl not found at %s; skipping macOS VM provisioning\n' "$UTMCTL"
    return
  fi

  vm_count=$(jq '.vms | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".vms[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".vms[$i].display" "$MANIFEST")
    vm_type=$(jq -r ".vms[$i].type" "$MANIFEST")

    if ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    bundle="$VM_DIR/${vm_name}.utm"
    images_dir="$bundle/Images"
    disk_file="$images_dir/disk-main.qcow2"
    config_plist="$bundle/config.plist"

    printf 'VM-setup: configuring UTM VM "%s"...\n' "$vm_display"

    # Check if bundle already exists to avoid overwriting.
    if [ -d "$bundle" ]; then
      printf 'VM-setup: UTM bundle already exists: %s; skipping\n' "$bundle"
      i=$((i + 1))
      continue
    fi

    # Use the Nix-generated UTM config.plist written to ~/.local/share/nucleus/
    # at Home Manager activation time (run nucleus-apply first).
    _plist_template="${HOME}/.local/share/nucleus/vms/${vm_name}-config.plist"
    if [ ! -f "$_plist_template" ]; then
      printf 'VM-setup: WARNING \u2014 UTM config template not found at %s; apply the macOS config first\n' "$_plist_template" >&2
      i=$((i + 1))
      continue
    fi

    # Require a pre-built image (built in phase 1).
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
    if [ ! -f "$_prebuilt" ]; then
      printf 'VM-setup: WARNING \u2014 image not found: %s; build failed or type not supported\n' "$_prebuilt" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      mkdir -p "$images_dir"
      cp "$_prebuilt" "$disk_file"
      cp "$_plist_template" "$config_plist"
      printf 'VM-setup: UTM bundle created: %s\n' "$bundle"
      # Register with UTM by opening the bundle package.
      open "$bundle"
      write_configure_script "$vm_name" "$vm_type"
    else
      printf 'VM-setup: [dry-run] create UTM bundle %s from %s\n' "$bundle" "$_plist_template"
    fi

    i=$((i + 1))
  done

  printf 'VM-setup: macOS VM setup complete\n'
}

# ---------------------------------------------------------------------------
# NixOS / libvirt
# ---------------------------------------------------------------------------

setup_libvirt_vms() {
  if ! command -v virsh >/dev/null 2>&1; then
    printf 'VM-setup: virsh not found in PATH; libvirtd may not be enabled yet\n'
    printf 'VM-setup: apply the NixOS configuration first so VMs.nix activates libvirtd\n'
    return
  fi

  # Ensure the libvirt default network is started so VMs can reach the host.
  if virsh net-list --all 2>/dev/null | grep -q "default"; then
    if ! virsh net-list 2>/dev/null | grep -q "default.*active"; then
      printf 'VM-setup: starting libvirt default network...\n'
      run_cmd virsh net-start default || true
      run_cmd virsh net-autostart default || true
    fi
  fi

  vm_count=$(jq '.vms | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".vms[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".vms[$i].display" "$MANIFEST")
    vm_type=$(jq -r ".vms[$i].type" "$MANIFEST")

    if ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    disk_path="$VM_DIR/${vm_name}.qcow2"

    printf 'VM-setup: configuring libvirt VM "%s"...\n' "$vm_display"

    # Require a pre-built image (built in phase 1).
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
    if [ ! -f "$_prebuilt" ]; then
      printf 'VM-setup: WARNING \u2014 image not found: %s; skipping "%s"\n' "$_prebuilt" "$vm_name" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      mkdir -p "$VM_DIR"
      if [ ! -f "$disk_path" ]; then
        cp "$_prebuilt" "$disk_path"
        printf 'VM-setup: disk image placed: %s\n' "$disk_path"
      else
        printf 'VM-setup: disk already exists: %s\n' "$disk_path"
      fi
    else
      printf 'VM-setup: [dry-run] copy %s to %s\n' "$_prebuilt" "$disk_path"
    fi

    # Define/update the libvirt domain from the Nix-generated XML (idempotent).
    # The file is installed at apply time by environment.etc in VMs.nix.
    _xml_file="/etc/nucleus/vms/${vm_name}-domain.xml"
    if [ ! -f "$_xml_file" ]; then
      printf 'VM-setup: WARNING — domain XML not found at %s; apply the NixOS config first\n' "$_xml_file" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      if virsh define "$_xml_file"; then
        printf 'VM-setup: VM "%s" defined/updated in libvirt\n' "$vm_name"
        write_configure_script "$vm_name" "$vm_type"
      else
        printf 'VM-setup: WARNING — virsh define failed for "%s"; check libvirtd status\n' "$vm_name" >&2
      fi
    else
      printf 'VM-setup: [dry-run] virsh define %s\n' "$_xml_file"
    fi

    i=$((i + 1))
  done

  printf 'VM-setup: NixOS VM setup complete; use virt-manager to start VMs\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf 'VM-setup: reading manifest from %s\n' "$MANIFEST"
if [ "$dry_run" = true ]; then
  printf 'VM-setup: dry-run mode — no changes will be made\n'
fi

if [ "$dry_run" = false ]; then
  mkdir -p "$VM_DIR"
  mkdir -p "$IMAGES_DIR"
fi

printf 'VM-setup: phase 1 \u2014 building images...\n'
build_images

printf 'VM-setup: phase 2 \u2014 provisioning VMs...\n'
_os=$(uname -s)
case "$_os" in
  Darwin)
    setup_utm_vms
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      setup_libvirt_vms
    else
      printf 'VM-setup: standalone Linux detected; use QEMU/KVM directly:\n'
      printf 'VM-setup:   qemu-img create -f qcow2 ~/virtual\ machines/<name>.qcow2 <size>G\n'
      printf 'VM-setup:   qemu-system-x86_64 -m <ram> -smp <cpu> -hda ~/virtual\ machines/<name>.qcow2 ...\n'
    fi
    ;;
  *)
    printf 'VM-setup: unsupported OS "%s"; nothing to do\n' "$_os"
    ;;
esac

printf 'VM-setup: done\n'
