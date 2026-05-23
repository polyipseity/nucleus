#!/usr/bin/env sh
# Provisions and configures virtual machines declared in src/modules/vms.json.
#
# What it does:
#   macOS  (Darwin): creates UTM VM bundles in the UTM document store, pre-allocates
#                    QCOW2 disk images, and configures VirtioFS sharing for ~/dev.
#   NixOS  (Linux/NIXOS): writes libvirt domain XML for each VM and registers it
#                    with virsh so KVM-accelerated VMs are ready for use.
#   Other Linux:     prints instructions for manual QEMU setup.
#
# Disk format: QCOW2 throughout (UTM, libvirt/QEMU, and Windows QEMU all speak
# QCOW2 natively), enabling copy-based migration between all three platforms.
#
# Arguments:
#   --dry-run  print planned actions without executing them
#
# Environment variables:
#   VM_DIR_OVERRIDE  override the default ~/Virtual Machines path
#
# Prerequisites:
#   macOS:  UTM installed (/Applications/UTM.app); qemu-img in PATH for
#           disk pre-allocation (falls back to sparse raw file if absent).
#   NixOS:  virsh in PATH (provided by the libvirt package in vms.nix);
#           qemu-img in PATH (provided by qemu in vms.nix).
#
# Exit: always 0 (best-effort — a VM setup failure does not roll back a
#       completed system apply).

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/src/modules/vms.json"

dry_run=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    *)
      printf 'vm-setup: unsupported argument "%s"\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$MANIFEST" ]; then
  printf 'vm-setup: manifest not found at %s; skipping\n' "$MANIFEST" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'vm-setup: jq not found in PATH; cannot parse manifest\n' >&2
  exit 0
fi

VM_DIR="${VM_DIR_OVERRIDE:-$HOME/Virtual Machines}"

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

create_qcow2_disk() {
  _disk_path="$1"
  _disk_gib="$2"
  if [ -f "$_disk_path" ]; then
    printf 'vm-setup: disk already exists: %s\n' "$_disk_path"
    return
  fi
  if command -v qemu-img >/dev/null 2>&1; then
    printf 'vm-setup: creating QCOW2 disk (%s GiB): %s\n' "$_disk_gib" "$_disk_path"
    run_cmd qemu-img create -f qcow2 "$_disk_path" "${_disk_gib}G"
  else
    # Fallback: create a sparse raw disk image.  On macOS this produces a
    # sparse file via HFS+/APFS copy-on-write; on Linux via ext4 sparse blocks.
    # The guest can use this as a raw disk; convert to QCOW2 later with
    # `qemu-img convert -f raw -O qcow2 <raw> <qcow2>`.
    printf 'vm-setup: qemu-img not found; creating sparse raw disk (%s GiB): %s\n' "$_disk_gib" "$_disk_path"
    run_cmd dd if=/dev/zero bs=1 count=0 seek=$((_disk_gib * 1073741824)) of="$_disk_path" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# macOS / UTM
# ---------------------------------------------------------------------------

setup_utm_vms() {
  UTM_DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

  if [ ! -d /Applications/UTM.app ]; then
    printf 'vm-setup: UTM not found at /Applications/UTM.app; skipping macOS VM provisioning\n'
    return
  fi

  if [ ! -x "$UTMCTL" ]; then
    printf 'vm-setup: utmctl not found at %s; skipping macOS VM provisioning\n' "$UTMCTL"
    return
  fi

  if [ ! -d "$UTM_DOCS" ]; then
    # UTM has never been launched; its sandboxed document directory is absent.
    printf 'vm-setup: UTM document directory not found; launch UTM at least once before running vm-setup\n'
    return
  fi

  vm_count=$(jq '.vms | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".vms[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".vms[$i].display" "$MANIFEST")
    vm_cpus=$(jq -r ".vms[$i].cpus" "$MANIFEST")
    vm_ram=$(jq -r ".vms[$i].ramMiB" "$MANIFEST")
    vm_disk=$(jq -r ".vms[$i].diskGiB" "$MANIFEST")
    vm_type=$(jq -r ".vms[$i].type" "$MANIFEST")
    vm_share_dev=$(jq -r ".vms[$i].shareDevDir" "$MANIFEST")

    bundle="$UTM_DOCS/${vm_name}.utm"
    images_dir="$bundle/Images"
    disk_file="$images_dir/disk-main.qcow2"
    config_plist="$bundle/config.plist"

    printf 'vm-setup: configuring UTM VM "%s"...\n' "$vm_display"

    # Check if VM is already registered to avoid overwriting a running VM.
    if "$UTMCTL" list 2>/dev/null | grep -qF "$vm_display"; then
      printf 'vm-setup: VM "%s" already registered in UTM; skipping\n' "$vm_display"
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      mkdir -p "$images_dir"
    else
      printf 'vm-setup: [dry-run] mkdir -p %s\n' "$images_dir"
    fi

    # Pre-allocate the disk.
    if [ "$dry_run" = false ]; then
      create_qcow2_disk "$disk_file" "$vm_disk"
    else
      printf 'vm-setup: [dry-run] create_qcow2_disk %s %s\n' "$disk_file" "$vm_disk"
    fi

    # Determine host architecture for the VM machine type.
    _host_arch=$(uname -m)
    if [ "$_host_arch" = "arm64" ]; then
      _arch="aarch64"
      _machine="virt"
      if [ "$vm_type" = "windows" ]; then
        _display_card="vga"
      else
        _display_card="virtio-ramfb-gl"
      fi
    else
      _arch="x86_64"
      _machine="q35"
      if [ "$vm_type" = "windows" ]; then
        _display_card="vga"
      else
        _display_card="virtio-gpu-pci"
      fi
    fi

    _uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '00000000-0000-0000-0000-000000000001')

    # Generate UTM config.plist using PlistBuddy (always available on macOS).
    # The plist structure follows UTM 4.x QEMU backend format.
    # Source: https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration.swift
    PB="/usr/libexec/PlistBuddy"

    if [ "$dry_run" = false ]; then
      # Initialise empty plist.
      "$PB" -c "Clear dict" "$config_plist"

      # Backend and version.
      "$PB" -c "Add :Backend string qemu" "$config_plist"
      "$PB" -c "Add :ConfigurationVersion integer 4" "$config_plist"

      # VM identity.
      "$PB" -c "Add :Information dict" "$config_plist"
      "$PB" -c "Add :Information:Icon string generic" "$config_plist"
      "$PB" -c "Add :Information:Name string ${vm_display}" "$config_plist"
      "$PB" -c "Add :Information:UUID string ${_uuid}" "$config_plist"

      # CPU and memory.
      "$PB" -c "Add :System dict" "$config_plist"
      "$PB" -c "Add :System:Architecture string ${_arch}" "$config_plist"
      "$PB" -c "Add :System:CPU string default" "$config_plist"
      "$PB" -c "Add :System:CPUCount integer ${vm_cpus}" "$config_plist"
      "$PB" -c "Add :System:CPUFlags array" "$config_plist"
      "$PB" -c "Add :System:ForceMulticore bool false" "$config_plist"
      "$PB" -c "Add :System:JITCacheSize integer 0" "$config_plist"
      "$PB" -c "Add :System:MemorySize integer ${vm_ram}" "$config_plist"
      "$PB" -c "Add :System:Target string ${_machine}" "$config_plist"

      # Disk drive.
      "$PB" -c "Add :Drives array" "$config_plist"
      "$PB" -c "Add :Drives:0 dict" "$config_plist"
      "$PB" -c "Add :Drives:0:Bootable bool false" "$config_plist"
      "$PB" -c "Add :Drives:0:Fixed bool false" "$config_plist"
      "$PB" -c "Add :Drives:0:ImagePath string Images/disk-main.qcow2" "$config_plist"
      "$PB" -c "Add :Drives:0:ImageType string Disk" "$config_plist"
      "$PB" -c "Add :Drives:0:Interface string virtio" "$config_plist"
      "$PB" -c "Add :Drives:0:ReadOnly bool false" "$config_plist"

      # Display.
      "$PB" -c "Add :Display dict" "$config_plist"
      "$PB" -c "Add :Display:Card string ${_display_card}" "$config_plist"
      "$PB" -c "Add :Display:FitScreen bool true" "$config_plist"

      # Network (shared/NAT).
      "$PB" -c "Add :Network array" "$config_plist"
      "$PB" -c "Add :Network:0 dict" "$config_plist"
      "$PB" -c "Add :Network:0:Hardware string virtio-net-pci" "$config_plist"
      "$PB" -c "Add :Network:0:Mode string Shared" "$config_plist"
      "$PB" -c "Add :Network:0:PortForward array" "$config_plist"

      # Clipboard sharing and VirtioFS host directory share.
      "$PB" -c "Add :Sharing dict" "$config_plist"
      "$PB" -c "Add :Sharing:ClipboardShare bool true" "$config_plist"
      if [ "$vm_share_dev" = "true" ]; then
        "$PB" -c "Add :Sharing:DirectoryReadOnly bool false" "$config_plist"
        "$PB" -c "Add :Sharing:DirectoryShare string ${HOME}/dev" "$config_plist"
      fi

      # Serial console (empty; QEMU window used for display).
      "$PB" -c "Add :Serial array" "$config_plist"

      # Sound.
      "$PB" -c "Add :Sound array" "$config_plist"
      "$PB" -c "Add :Sound:0 dict" "$config_plist"
      "$PB" -c "Add :Sound:0:Hardware string intel-hda" "$config_plist"

      printf 'vm-setup: UTM bundle created: %s\n' "$bundle"
      printf 'vm-setup: open UTM to install the guest OS on the "%s" VM\n' "$vm_display"
    else
      printf 'vm-setup: [dry-run] create UTM bundle %s\n' "$bundle"
    fi

    i=$((i + 1))
  done

  printf 'vm-setup: macOS VM setup complete; open UTM to manage VMs\n'
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

  vm_count=$(jq '.vms | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".vms[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".vms[$i].display" "$MANIFEST")
    vm_cpus=$(jq -r ".vms[$i].cpus" "$MANIFEST")
    vm_ram=$(jq -r ".vms[$i].ramMiB" "$MANIFEST")
    vm_disk=$(jq -r ".vms[$i].diskGiB" "$MANIFEST")
    vm_type=$(jq -r ".vms[$i].type" "$MANIFEST")
    vm_share_dev=$(jq -r ".vms[$i].shareDevDir" "$MANIFEST")

    disk_path="$VM_DIR/${vm_name}.qcow2"

    printf 'vm-setup: configuring libvirt VM "%s"...\n' "$vm_display"

    # Check if VM is already defined.
    if virsh dominfo "$vm_name" >/dev/null 2>&1; then
      printf 'vm-setup: VM "%s" already defined in libvirt; skipping\n' "$vm_name"
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      mkdir -p "$VM_DIR"
      create_qcow2_disk "$disk_path" "$vm_disk"
    else
      printf 'vm-setup: [dry-run] create disk %s (%s GiB)\n' "$disk_path" "$vm_disk"
    fi

    # Determine host architecture for the VM machine type.
    _host_arch=$(uname -m)
    if [ "$_host_arch" = "aarch64" ]; then
      _arch="aarch64"
      _machine="virt"
      _emulator="/run/current-system/sw/bin/qemu-system-aarch64"
      _cpu="host"
      _video_model="virtio"
    else
      _arch="x86_64"
      _machine="q35"
      _emulator="/run/current-system/sw/bin/qemu-system-x86_64"
      _cpu="host"
      _video_model="virtio"
    fi

    if [ "$vm_type" = "windows" ]; then
      _video_model="vga"
    fi

    # VirtioFS shared directory configuration.
    _virtiofs_xml=""
    if [ "$vm_share_dev" = "true" ]; then
      _virtiofs_xml="
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='${HOME}/dev'/>
      <target dir='dev'/>
    </filesystem>"
    fi

    # Generate libvirt domain XML and define the VM.
    _xml_tmp=$(mktemp /tmp/vm-setup-XXXXXX.xml)
    cat > "$_xml_tmp" << XMLEOF
<domain type='kvm'>
  <name>${vm_name}</name>
  <title>${vm_display}</title>
  <memory unit='MiB'>${vm_ram}</memory>
  <vcpu>${vm_cpus}</vcpu>
  <os>
    <type arch='${_arch}' machine='${_machine}'>hvm</type>
    <boot dev='hd'/>
  </os>
  <cpu mode='host-passthrough'/>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <emulator>${_emulator}</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${disk_path}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <video>
      <model type='${_video_model}'/>
    </video>
    <graphics type='spice' autoport='yes'>
      <listen type='address'/>
      <image compression='off'/>
    </graphics>
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>${_virtiofs_xml}
    <memballoon model='virtio'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
XMLEOF

    if [ "$dry_run" = false ]; then
      if virsh define "$_xml_tmp"; then
        printf 'vm-setup: VM "%s" defined in libvirt\n' "$vm_name"
        printf 'vm-setup: install a guest OS via: virt-manager or virsh console %s\n' "$vm_name"
      else
        printf 'vm-setup: WARNING — virsh define failed for "%s"; check libvirtd status\n' "$vm_name" >&2
      fi
    else
      printf 'vm-setup: [dry-run] virsh define %s\n' "$_xml_tmp"
    fi

    rm -f "$_xml_tmp"
    i=$((i + 1))
  done

  printf 'vm-setup: NixOS VM setup complete; use virt-manager to install guest OSes\n'
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
fi

_os=$(uname -s)
case "$_os" in
  Darwin)
    setup_utm_vms
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      setup_libvirt_vms
    else
      printf 'vm-setup: standalone Linux detected; use QEMU/KVM directly:\n'
      printf 'vm-setup:   qemu-img create -f qcow2 ~/Virtual\ Machines/<name>.qcow2 <size>G\n'
      printf 'vm-setup:   qemu-system-x86_64 -m <ram> -smp <cpu> -hda ~/Virtual\ Machines/<name>.qcow2 ...\n'
    fi
    ;;
  *)
    printf 'vm-setup: unsupported OS "%s"; nothing to do\n' "$_os"
    ;;
esac

printf 'vm-setup: done\n'
