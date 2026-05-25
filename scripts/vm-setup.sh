#!/usr/bin/env sh
# scripts/vm-setup.sh — Build VM images (if needed) and provision VMs.
#
# Combines the former nucleus-VM-build and nucleus-vm-setup into one command.
# Phase 1 builds pre-built QCOW2 OS images (if absent) using
# nixos-generators (NixOS guest on macOS/NixOS) or Packer (Windows).
# Phase 2 provisions VM bundles/domains from those images.
#
# Usage:
#   scripts/vm-setup.sh [options]
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
#   NixOS guest    : nix (for nix run github:nix-community/nixos-generators).
#   Windows guest  : packer (pkgs.packer), QEMU, ISO auto-fetched via Fido.
#   macOS guest    : tart (brew install cirruslabs/cli/tart), packer; macOS host only.
#   macOS host     : UTM installed (/Applications/UTM.app); qemu-img in PATH.
#   NixOS host     : libvirtd enabled (vms.nix); qemu-img and virsh in PATH.
#
# Exit: always 0 (best-effort — a VM setup failure does not roll back a
#       completed system apply).
#
# Run as alias:
#   nucleus-vm-setup  (equivalent to scripts/vm-setup.sh)
#
# Source: https://github.com/nix-community/nixos-generators
#         https://developer.hashicorp.com/packer/plugins/builders/qemu
#         https://github.com/cirruslabs/packer-plugin-tart
#         https://github.com/pbatard/Fido

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
      printf 'vm-setup: unknown argument: %s\n' "$1" >&2
      printf 'vm-setup: usage: %s [--dry-run] [--nixos-only|--windows-only] [--windows-iso PATH] [--accelerator TYPE]\n' "$0" >&2
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
  printf 'vm-setup: manifest not found at %s; skipping\n' "$MANIFEST" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'vm-setup: jq not found in PATH; cannot parse manifest\n' >&2
  exit 0
fi

VM_DIR="${VM_DIR_OVERRIDE:-$HOME/virtual machines}"
IMAGES_DIR="$VM_DIR/images"

# should_include TYPE — returns 0 if a VM of the given type should be processed.
should_include() {
  _type="$1"
  if [ "$nixos_only" = true ] && [ "$_type" != "NixOS" ]; then
    return 1
  fi
  if [ "$windows_only" = true ] && [ "$_type" != "Windows" ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_cmd() {
  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] %s\n' "$*"
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
    printf 'vm-setup: NixOS image already built (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  _guest_nix="$VMS_DIR/nixos/guest.nix"
  if [ ! -f "$_guest_nix" ]; then
    printf 'vm-setup: nixos guest config not found: %s\n' "$_guest_nix" >&2
    return 1
  fi

  printf 'vm-setup: building NixOS image (system=%s, format=%s)...\n' \
    "$_nixos_system" "$_nixos_format"

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] nix run github:nix-community/nixos-generators -- --format %s --system %s --configuration %s -o <tmpdir>\n' \
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
    printf 'vm-setup: nixos-generators produced no .qcow2 in %s\n' "$_tmpdir" >&2
    rm -rf "$_tmpdir"
    return 1
  fi
  # -L follows symlinks so we copy the actual disk image bytes.
  cp -L "$_img" "$_out"
  rm -rf "$_tmpdir"
  printf 'vm-setup: NixOS image ready: %s\n' "$_out"
}

# download_windows_iso_mido CACHED_ISO EDITION
#   Downloads a Windows 11 ISO using vendor/qvm-create-windows-qube/windows/isos/mido.sh.
#   Mido is the secure Microsoft Windows Downloader for UNIX systems.
#   The EDITION parameter maps to a Mido media identifier.
#   Returns 0 on success, 1 on failure.
#   Requires curl in PATH.
#   Source: https://github.com/QubesOS/qvm-create-windows-qube
download_windows_iso_mido() {
  _mido_cached="$1"
  _mido_edition="${2:-Pro}"

  _mido_script="$REPO_ROOT/vendor/qvm-create-windows-qube/windows/isos/mido.sh"
  if [ ! -f "$_mido_script" ]; then
    printf 'vm-setup: mido.sh not found; run: git submodule update --init vendor/qvm-create-windows-qube\n' >&2
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf 'vm-setup: curl not found; required for Mido ISO download\n' >&2
    return 1
  fi

  # Map edition to Mido media identifier.
  # Consumer multi-edition ISO (win11x64) covers Home/Pro/Edu; the
  # answer file selects the exact edition during unattended setup.
  # Source: Mido usage in windows/isos/mido.sh
  case "$(printf '%s' "$_mido_edition" | tr '[:upper:]' '[:lower:]')" in
    *enterprise*eval*) _mido_media='win11x64-enterprise-eval' ;;
    *) _mido_media='win11x64' ;;
  esac

  printf 'vm-setup: downloading Windows 11 ISO via Mido (media=%s)...\n' "$_mido_media"

  _mido_tmp="$(mktemp -d)"
  _mido_dir="$(CDPATH='' cd -- "$(dirname -- "$_mido_script")" && pwd)"
  _mido_status=0
  (
    cd "$_mido_tmp"
    # Add Mido's directory to PATH to keep the download in _mido_tmp instead
    # of Mido's own directory.
    # WHY: mido.sh checks if its parent directory is in PATH; if so it stays
    # in PWD.  Without this, Mido cd-s to its own directory and writes the
    # ISO there instead of _mido_tmp.
    # Source: path detection logic at bottom of mido.sh
    PATH="${_mido_dir}:${PATH}" sh "$_mido_script" "$_mido_media"
  ) || _mido_status=$?

  # Exit code 4 means verification failed but the ISO was downloaded as
  # .iso.UNVERIFIED (common for newer ISOs not yet in Mido's checksum list).
  # Accept the file and proceed; the caller can verify manually if desired.
  # Source: Mido exit codes in the ending_summary function of mido.sh
  if [ "$_mido_status" -ne 0 ] && [ "$_mido_status" -ne 4 ]; then
    printf 'vm-setup: Mido exited with code %s\n' "$_mido_status" >&2
    rm -rf "$_mido_tmp"
    return 1
  fi

  _mido_iso="$(find "$_mido_tmp" -maxdepth 1 \( -name '*.iso' -o -name '*.iso.UNVERIFIED' \) -print -quit 2>/dev/null)"
  if [ -z "$_mido_iso" ]; then
    printf 'vm-setup: Mido: no ISO found in temp dir after download\n' >&2
    rm -rf "$_mido_tmp"
    return 1
  fi

  mv "$_mido_iso" "$_mido_cached"
  rm -rf "$_mido_tmp"
  printf 'vm-setup: Windows ISO downloaded: %s\n' "$_mido_cached"
  return 0
}

# download_windows_iso_fido CACHED_ISO EDITION
#   Downloads a Windows 11 ISO using vendor/Fido/Fido.ps1 (the same engine
#   that drives Rufus download automation).  Moves the downloaded ISO to
#   CACHED_ISO on success; returns 0 on success, 1 on failure.
#   Requires pwsh (PowerShell Core) in PATH.
#   Source: https://github.com/pbatard/Fido
download_windows_iso_fido() {
  _fido_cached="$1"
  _fido_edition="${2:-Pro}"

  _fido_script="$REPO_ROOT/vendor/Fido/Fido.ps1"
  if [ ! -f "$_fido_script" ]; then
    printf 'vm-setup: Fido.ps1 not found; run: git submodule update --init vendor/Fido\n' >&2
    return 1
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    printf 'vm-setup: pwsh not found; cannot use Fido for ISO auto-download\n'
    return 1
  fi

  printf 'vm-setup: downloading Windows 11 ISO via Fido (edition=%s)...\n' "$_fido_edition"
  # Run Fido in a temp dir so it downloads the ISO to a known location.
  # Fido.ps1 downloads to the working directory and returns the filename.
  # Source: https://github.com/pbatard/Fido#usage
  _fido_tmp="$(mktemp -d)"
  _fido_status=0
  (
    cd "$_fido_tmp"
    pwsh -NonInteractive -ExecutionPolicy Bypass \
      -File "$_fido_script" \
      -Win 11 -Ed "$_fido_edition" -Lang English -Arch x64 \
      -Download -NoPrompt
  ) || _fido_status=$?

  if [ "$_fido_status" -ne 0 ]; then
    printf 'vm-setup: Fido exited with code %s\n' "$_fido_status" >&2
    rm -rf "$_fido_tmp"
    return 1
  fi

  # Use find rather than ls to safely handle any filename; Fido downloads one
  # ISO so sort-by-time is unnecessary.
  _fido_iso="$(find "$_fido_tmp" -maxdepth 1 -name '*.iso' | head -1)"
  if [ -z "$_fido_iso" ]; then
    printf 'vm-setup: Fido: no ISO found in temp dir after download\n' >&2
    rm -rf "$_fido_tmp"
    return 1
  fi

  mv "$_fido_iso" "$_fido_cached"
  rm -rf "$_fido_tmp"
  printf 'vm-setup: Windows ISO downloaded: %s\n' "$_fido_cached"
  return 0
}

# build_windows_image NAME DISK_GIB
#   Builds the Windows 11 guest image using Packer and the Autounattend.xml
#   answer file at vms/windows/Autounattend.xml.
build_windows_image() {
  _name="$1"
  _disk_gib="$2"
  _edition="${3:-Pro}"
  _out="$IMAGES_DIR/${_name}.qcow2"

  if [ -f "$_out" ]; then
    printf 'vm-setup: Windows image already built (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  # Resolve the installer ISO: use --windows-iso if provided, otherwise try the
  # windowsIsoUrl field from VMs.json as a download source.
  _iso="$windows_iso"
  if [ -z "$_iso" ]; then
    _iso_url="$(jq -r ".VMs[] | select(.name == \"$_name\") | .windowsIsoUrl // empty" "$MANIFEST")"
    if [ -n "$_iso_url" ]; then
      _cached_iso="$IMAGES_DIR/${_name}-installer.iso"
      if [ -f "$_cached_iso" ]; then
        printf 'vm-setup: using cached Windows installer: %s\n' "$_cached_iso"
        _iso="$_cached_iso"
      else
        printf 'vm-setup: downloading Windows installer from windowsIsoUrl...\n'
        if [ "$dry_run" = false ]; then
          curl -fL -o "$_cached_iso" "$_iso_url" || {
            printf 'vm-setup: download failed; remove %s and retry\n' "$_cached_iso" >&2
            rm -f "$_cached_iso"
            return 1
          }
          _iso="$_cached_iso"
          printf 'vm-setup: Windows installer downloaded: %s\n' "$_cached_iso"
        else
          printf 'vm-setup: [dry-run] curl -fL -o %s %s\n' "$_cached_iso" "$_iso_url"
        fi
      fi
    fi
  fi

  # If still no ISO resolved, attempt download via Mido (UNIX-native) or Fido
  # (PowerShell, Windows-native) depending on what is available.
  # WHY Mido first: Mido is a POSIX sh + curl script that works on macOS and
  # Linux; Fido requires pwsh and Windows-specific APIs that fail on non-Windows.
  # Source: https://github.com/QubesOS/qvm-create-windows-qube
  if [ -z "$_iso" ]; then
    _cached_iso="$IMAGES_DIR/${_name}-installer.iso"
    if [ -f "$_cached_iso" ]; then
      printf 'vm-setup: using cached Windows installer: %s\n' "$_cached_iso"
      _iso="$_cached_iso"
    else
      if [ "$dry_run" = false ]; then
        if download_windows_iso_mido "$_cached_iso" "$_edition"; then
          _iso="$_cached_iso"
        elif download_windows_iso_fido "$_cached_iso" "$_edition"; then
          _iso="$_cached_iso"
        fi
      else
        printf 'vm-setup: [dry-run] would call vendor/qvm-create-windows-qube/windows/isos/mido.sh (or Fido fallback) to download Windows 11 ISO\n'
      fi
    fi
  fi

  if [ -z "$_iso" ]; then
    printf 'vm-setup: --windows-iso PATH is required for Windows 11 builds\n' >&2
    printf 'vm-setup: alternatively add "windowsIsoUrl": "<url>" to the VMs.json windows entry\n' >&2
    printf 'vm-setup: download from: https://www.microsoft.com/software-download/windows11\n' >&2
    return 1
  fi

  if [ ! -f "$_iso" ]; then
    printf 'vm-setup: Windows ISO not found: %s\n' "$_iso" >&2
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    printf 'vm-setup: packer not found; install via nixpkgs (pkgs.packer is in baseSharedPackages)\n' >&2
    return 1
  fi

  # Pre-download VirtIO drivers ISO so it can be injected into the build via
  # secondary_iso_images (used by Autounattend.xml FirstLogonCommands).
  # Falls back to runtime download in the Packer provisioner if this fails.
  # Source: https://fedorapeople.org/groups/virt/virtio-win/
  _virtio_iso="$IMAGES_DIR/virtio-win.iso"
  if [ ! -f "$_virtio_iso" ] && [ "$dry_run" = false ]; then
    printf 'vm-setup: downloading VirtIO drivers ISO...\n'
    _virtio_url='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
    curl -fL -o "$_virtio_iso" "$_virtio_url" || {
      printf 'vm-setup: VirtIO ISO pre-download failed; Packer provisioner will download at runtime\n' >&2
      _virtio_iso=''
    }
  fi

  _packer_dir="$VMS_DIR/windows"
  _tmp_out="$IMAGES_DIR/${_name}-build"

  printf 'vm-setup: building Windows 11 image (disk=%s GiB, accelerator=%s)...\n' \
    "$_disk_gib" "$accelerator"

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] cd %s && packer build -var windows_iso=%s -var accelerator=%s -var disk_size=%sG -var output_directory=%s .\n' \
      "$_packer_dir" "$_iso" "$accelerator" "$_disk_gib" "$_tmp_out"
    return 0
  fi

  (
    cd "$_packer_dir"
    packer init .
    packer build \
      -var "windows_iso=$_iso" \
      -var "accelerator=$accelerator" \
      -var "disk_size=${_disk_gib}G" \
      -var "output_directory=$_tmp_out" \
      ${_virtio_iso:+-var "virtio_win_iso=$_virtio_iso"} \
      .
  )

  _built="$_tmp_out/windows.qcow2"
  if [ ! -f "$_built" ]; then
    printf 'vm-setup: Packer did not produce %s\n' "$_built" >&2
    return 1
  fi

  mv "$_built" "$_out"
  rm -rf "$_tmp_out"
  printf 'vm-setup: Windows 11 image ready: %s\n' "$_out"
}

# build_macos_image NAME DISK_GIB RAM_MIB CPUS MACOS_VERSION
#   Builds the macOS guest VM using the Packer Tart plugin.  Requires tart
#   and packer to be installed; only runs on Darwin hosts (Tart uses Apple
#   Virtualization.framework which is not available on other platforms).
#   The resulting VM is stored in ~/.tart/vms/<name>/ managed by tart.
#   Source: https://github.com/cirruslabs/packer-plugin-tart
build_macos_image() {
  _name="$1"
  _disk_gib="$2"
  _ram_mib="$3"
  _cpus="$4"
  _macos_version="${5:-sequoia}"

  # Tart requires Apple Virtualization.framework — macOS host only.
  if [ "$(uname -s)" != "Darwin" ]; then
    printf 'vm-setup: macOS guest build requires a macOS host (Tart uses Virtualization.framework); skipping\n'
    return 0
  fi

  if ! command -v tart >/dev/null 2>&1; then
    printf 'vm-setup: tart not found; install with: brew install cirruslabs/cli/tart\n' >&2
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    printf 'vm-setup: packer not found; install via nixpkgs (pkgs.packer)\n' >&2
    return 1
  fi

  # Check if tart VM already exists.
  if tart list 2>/dev/null | awk '{print $1}' | grep -qxF "$_name"; then
    printf 'vm-setup: tart VM "%s" already exists (delete to rebuild: tart delete %s)\n' "$_name" "$_name"
    return 0
  fi

  _packer_dir="$VMS_DIR/macos"
  # Round MiB to nearest GiB for Tart (which accepts integer GiB only).
  # Uses (n + 512) / 1024 for round-half-up in integer arithmetic.
  _mem_gib="$(( (_ram_mib + 512) / 1024 ))"

  printf 'vm-setup: building macOS %s VM via Packer Tart (disk=%s GiB, mem=%s GiB, cpus=%s)...\n' \
    "$_macos_version" "$_disk_gib" "$_mem_gib" "$_cpus"

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] cd %s && packer build -var vm_name=%s -var macos_version=%s -var disk_size_gib=%s -var memory_gib=%s -var cpus=%s .\n' \
      "$_packer_dir" "$_name" "$_macos_version" "$_disk_gib" "$_mem_gib" "$_cpus"
    return 0
  fi

  (
    cd "$_packer_dir"
    packer init .
    packer build \
      -var "vm_name=$_name" \
      -var "macos_version=$_macos_version" \
      -var "disk_size_gib=$_disk_gib" \
      -var "memory_gib=$_mem_gib" \
      -var "cpus=$_cpus" \
      .
  )

  printf 'vm-setup: macOS VM "%s" built and registered in tart\n' "$_name"
}

build_images() {
  _count="$(jq '.VMs | length' "$MANIFEST")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _vm_name="$(jq -r ".VMs[$_i].name" "$MANIFEST")"
    _vm_type="$(jq -r ".VMs[$_i].type" "$MANIFEST")"
    _vm_disk_bytes="$(jq -r ".VMs[$_i].diskBytes" "$MANIFEST")"
    # Convert SI bytes to nearest binary GiB for hypervisor tools.
    # Uses (n + 2^29) / 2^30 for round-half-up in POSIX integer arithmetic.
    _vm_disk_gib="$(( (_vm_disk_bytes + 536870912) / 1073741824 ))"

    if should_include "$_vm_type"; then
      case "$_vm_type" in
        NixOS)   build_nixos_image "$_vm_name" ;;
        Windows)
          _vm_edition="$(jq -r ".VMs[$_i].windowsEdition // \"Pro\"" "$MANIFEST")"
          build_windows_image "$_vm_name" "$_vm_disk_gib" "$_vm_edition"
          ;;
        macOS)
          _vm_macos_ver="$(jq -r ".VMs[$_i].macOSVersion // \"sequoia\"" "$MANIFEST")"
          _vm_ram_bytes="$(jq -r ".VMs[$_i].ramBytes" "$MANIFEST")"
          # Convert SI bytes to nearest binary MiB for hypervisor tools.
          # Uses (n + 2^19) / 2^20 for round-half-up in POSIX integer arithmetic.
          _vm_ram_mib="$(( (_vm_ram_bytes + 524288) / 1048576 ))"
          _vm_cpus="$(jq -r ".VMs[$_i].cpus" "$MANIFEST")"
          build_macos_image "$_vm_name" "$_vm_disk_gib" "$_vm_ram_mib" "$_vm_cpus" "$_vm_macos_ver"
          ;;
        *)
          printf 'vm-setup: skipping build for "%s" (unsupported type: %s)\n' \
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
    NixOS)
      cat > "$_wcs_script" << 'CFGEOF'
#!/usr/bin/env sh
# Apply the nucleus nixos host configuration inside this VM.
# ~/dev is shared via VirtioFS when shareDevDir=true.
sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#NixOS"
CFGEOF
      ;;
    Windows)
      cat > "$_wcs_script" << 'CFGEOF'
#!/usr/bin/env sh
# Apply the nucleus Windows host configuration inside this VM.
# Clone this repository to %USERPROFILE%\dev\nucleus inside the VM, then run:
#   .\src\hosts\Windows\apply.ps1
CFGEOF
      ;;
    macOS)
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
  printf 'vm-setup: wrote configure script: %s\n' "$_wcs_script"
}

# ---------------------------------------------------------------------------
# macOS / Tart (macOS guests)
# ---------------------------------------------------------------------------

# setup_tart_vms — Phase 2 provisioning for macOS-type VM guests.
#   The Packer Tart build already registered the VM in tart's store; this
#   function writes a start script and configure script for each macOS guest.
#   Source: https://github.com/cirruslabs/tart
setup_tart_vms() {
  if ! command -v tart >/dev/null 2>&1; then
    printf 'vm-setup: tart not found; skipping macOS VM start-script generation\n'
    return
  fi

  vm_count=$(jq '.VMs | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".VMs[$i].name" "$MANIFEST")
    vm_type=$(jq -r ".VMs[$i].type" "$MANIFEST")

    if [ "$vm_type" != "macOS" ] || ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    # Verify the tart VM was created in phase 1.
    if ! tart list 2>/dev/null | awk '{print $1}' | grep -qxF "$vm_name"; then
      printf 'vm-setup: WARNING — tart VM "%s" not found; Packer build may have failed or was skipped\n' "$vm_name" >&2
      i=$((i + 1))
      continue
    fi

    # Write a simple start script.
    _tart_start="$VM_DIR/Start-${vm_name}.sh"
    if [ "$dry_run" = false ]; then
      cat > "$_tart_start" << TARTEOF
#!/usr/bin/env sh
# Start the $vm_name macOS VM managed by tart.
# Source: https://github.com/cirruslabs/tart
exec tart run "$vm_name" "\$@"
TARTEOF
      chmod +x "$_tart_start"
      printf 'vm-setup: tart start script: %s\n' "$_tart_start"
      write_configure_script "$vm_name" "$vm_type"
    else
      printf 'vm-setup: [dry-run] write tart start script: %s\n' "$_tart_start"
    fi

    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# macOS / UTM (NixOS and Windows guests on macOS host)
# ---------------------------------------------------------------------------

setup_utm_vms() {
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

  if [ ! -d /Applications/UTM.app ]; then
    printf 'vm-setup: UTM not found at /Applications/UTM.app; skipping macOS VM provisioning\n'
    return
  fi

  if [ ! -x "$UTMCTL" ]; then
    printf 'vm-setup: utmctl not found at %s; skipping macOS VM provisioning\n' "$UTMCTL"
    return
  fi

  vm_count=$(jq '.VMs | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".VMs[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".VMs[$i].display" "$MANIFEST")
    vm_type=$(jq -r ".VMs[$i].type" "$MANIFEST")

    if ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    # macOS guests are provisioned via tart (setup_tart_vms), not UTM.
    if [ "$vm_type" = "macOS" ]; then
      i=$((i + 1))
      continue
    fi

    bundle="$VM_DIR/${vm_name}.utm"
    images_dir="$bundle/Images"
    disk_file="$images_dir/disk-main.qcow2"
    config_plist="$bundle/config.plist"

    printf 'vm-setup: configuring UTM VM "%s"...\n' "$vm_display"

    # Check if bundle already exists to avoid overwriting.
    if [ -d "$bundle" ]; then
      printf 'vm-setup: UTM bundle already exists: %s; skipping\n' "$bundle"
      i=$((i + 1))
      continue
    fi

    # Use the Nix-generated UTM config.plist written to ~/.local/share/nucleus/
    # at Home Manager activation time (run nucleus-apply first).
    _plist_template="${HOME}/.local/share/nucleus/vms/${vm_name}-config.plist"
    if [ ! -f "$_plist_template" ]; then
      printf 'vm-setup: WARNING \u2014 UTM config template not found at %s; apply the macOS config first\n' "$_plist_template" >&2
      i=$((i + 1))
      continue
    fi

    # Require a pre-built image (built in phase 1).
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
    if [ ! -f "$_prebuilt" ]; then
      printf 'vm-setup: WARNING \u2014 image not found: %s; build failed or type not supported\n' "$_prebuilt" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      mkdir -p "$images_dir"
      cp "$_prebuilt" "$disk_file"
      cp "$_plist_template" "$config_plist"
      printf 'vm-setup: UTM bundle created: %s\n' "$bundle"
      # Register with UTM by opening the bundle package.
      open "$bundle"
      write_configure_script "$vm_name" "$vm_type"
    else
      printf 'vm-setup: [dry-run] create UTM bundle %s from %s\n' "$bundle" "$_plist_template"
    fi

    i=$((i + 1))
  done

  printf 'vm-setup: macOS VM setup complete\n'
}

# ---------------------------------------------------------------------------
# NixOS / libvirt
# ---------------------------------------------------------------------------

setup_libvirt_vms() {
  if ! command -v virsh >/dev/null 2>&1; then
    printf 'vm-setup: virsh not found in PATH; libvirtd may not be enabled yet\n'
    printf 'vm-setup: apply the NixOS configuration first so vms.nix activates libvirtd\n'
    return
  fi

  # Ensure the libvirt default network is started so VMs can reach the host.
  if virsh net-list --all 2>/dev/null | grep -q "default"; then
    if ! virsh net-list 2>/dev/null | grep -q "default.*active"; then
      printf 'vm-setup: starting libvirt default network...\n'
      run_cmd virsh net-start default || true
      run_cmd virsh net-autostart default || true
    fi
  fi

  vm_count=$(jq '.VMs | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".VMs[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".VMs[$i].display" "$MANIFEST")
    vm_type=$(jq -r ".VMs[$i].type" "$MANIFEST")

    if ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    disk_path="$VM_DIR/${vm_name}.qcow2"

    printf 'vm-setup: configuring libvirt VM "%s"...\n' "$vm_display"

    # Require a pre-built image (built in phase 1).
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
    if [ ! -f "$_prebuilt" ]; then
      printf 'vm-setup: WARNING \u2014 image not found: %s; skipping "%s"\n' "$_prebuilt" "$vm_name" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      mkdir -p "$VM_DIR"
      if [ ! -f "$disk_path" ]; then
        cp "$_prebuilt" "$disk_path"
        printf 'vm-setup: disk image placed: %s\n' "$disk_path"
      else
        printf 'vm-setup: disk already exists: %s\n' "$disk_path"
      fi
    else
      printf 'vm-setup: [dry-run] copy %s to %s\n' "$_prebuilt" "$disk_path"
    fi

    # Define/update the libvirt domain from the Nix-generated XML (idempotent).
    # The file is installed at apply time by environment.etc in vms.nix.
    _xml_file="/etc/nucleus/vms/${vm_name}-domain.xml"
    if [ ! -f "$_xml_file" ]; then
      printf 'vm-setup: WARNING — domain XML not found at %s; apply the NixOS config first\n' "$_xml_file" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      if virsh define "$_xml_file"; then
        printf 'vm-setup: VM "%s" defined/updated in libvirt\n' "$vm_name"
        write_configure_script "$vm_name" "$vm_type"
      else
        printf 'vm-setup: WARNING — virsh define failed for "%s"; check libvirtd status\n' "$vm_name" >&2
      fi
    else
      printf 'vm-setup: [dry-run] virsh define %s\n' "$_xml_file"
    fi

    i=$((i + 1))
  done

  printf 'vm-setup: NixOS VM setup complete; use virt-manager to start VMs\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf 'vm-setup: reading manifest from %s\n' "$MANIFEST"
if [ "$dry_run" = true ]; then
  printf 'vm-setup: dry-run mode — no changes will be made\n'
fi

if [ "$dry_run" = false ]; then
  mkdir -p "$VM_DIR"
  mkdir -p "$IMAGES_DIR"
fi

printf 'vm-setup: phase 1 \u2014 building images...\n'
build_images

printf 'vm-setup: phase 2 \u2014 provisioning VMs...\n'
_os=$(uname -s)
case "$_os" in
  Darwin)
    setup_tart_vms
    setup_utm_vms
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      setup_libvirt_vms
    else
      printf 'vm-setup: standalone Linux detected; use QEMU/KVM directly:\n'
      printf 'vm-setup:   qemu-img create -f qcow2 ~/virtual\ machines/<name>.qcow2 <size>G\n'
      printf 'vm-setup:   qemu-system-x86_64 -m <ram> -smp <cpu> -hda ~/virtual\ machines/<name>.qcow2 ...\n'
    fi
    ;;
  *)
    printf 'vm-setup: unsupported OS "%s"; nothing to do\n' "$_os"
    ;;
esac

printf 'vm-setup: done\n'
