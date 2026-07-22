# MacBook/vms.nix — UTM VM configuration templates for the macOS host.
#
# Generates UTM 4.x QEMU-backend config.plist templates for each VM declared in
# src/modules/VMs.json.  Templates are written to
# ~/.local/share/nucleus/vms/<name>-config.plist at Home Manager activation time
# and consumed by scripts/vm-setup.sh (nucleus-vm-setup) to create UTM bundles
# without PlistBuddy invocations.
#
# The UUID for each VM is derived deterministically from the VM name via SHA-256
# so re-provisioning from scratch always produces the same UTM identity.
#
# Source: https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration.swift
{ pkgs, ... }:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/VMs.json);
  nucleusHost = "MacBook";
  enabledVms = builtins.filter (
    vm: vm.enabled && (!vm ? hosts || vm.hosts == null || builtins.elem nucleusHost vm.hosts)
  ) vmsData.VMs;

  isArm = pkgs.stdenv.hostPlatform.isAarch64;

  # Windows images in this repository are built as x86_64 QCOW2 artefacts.
  # Keep UTM system architecture aligned with the guest image architecture,
  # not with the host CPU architecture, so Apple Silicon hosts do not try to
  # import x86_64 guest bundles as aarch64 virtual machines.
  vmArch =
    vm:
    if vm.type == "Windows" then
      "x86_64"
    else if isArm then
      "aarch64"
    else
      "x86_64";
  vmMachine = vm: if vmArch vm == "x86_64" then "q35" else "virt";

  # UTM cannot use HVF for x86_64 guest emulation on Apple Silicon hosts.
  # Keep Hypervisor false in that case so imports/starts do not fail with an
  # invalid accelerator path; native-arch guests still use acceleration.
  qemuHypervisor = vm: if isArm then vmArch vm == "aarch64" else true;

  # Derive a deterministic UUID from the VM name (format: 8-4-4-4-12 hex).
  # The same name always maps to the same UUID so re-provisioning the same VM
  # produces a stable UTM identity across apply runs.
  mkUuid =
    name:
    let
      h = builtins.hashString "sha256" name;
    in
    "${builtins.substring 0 8 h}-${builtins.substring 8 4 h}-${builtins.substring 12 4 h}-${builtins.substring 16 4 h}-${builtins.substring 20 12 h}";

  # Deterministic locally-administered unicast MAC per VM name.
  mkMacAddress =
    name:
    let
      h = builtins.hashString "sha256" "mac:${name}";
    in
    "52:${builtins.substring 0 2 h}:${builtins.substring 2 2 h}:${builtins.substring 4 2 h}:${builtins.substring 6 2 h}:${builtins.substring 8 2 h}";

  # QEMU display card appropriate for the guest OS.
  # Linux/NixOS VMs use VirtIO GPU so UTM exposes an active display on both
  # Apple Silicon and Intel hosts.
  displayCard = vm: if vm.type == "Windows" then "virtio-vga" else "virtio-gpu-pci";

  # UTM 4.x sharing mode selector.
  # Modern UTM uses DirectoryShareMode/DirectoryShareReadOnly (not the legacy
  # DirectorySharing/ReadOnlySharing keys).  UTM import expects enum display
  # names (WebDAV/None), not lowercase raw values.
  directoryShareMode =
    vm: if vm.shareDevDir then "<string>WebDAV</string>" else "<string>None</string>";

  # Match firmware mode to the guest image build contract:
  # - Windows images are built BIOS/MBR (Autounattend.xml), so disable UEFI.
  # - NixOS images are qcow-efi on aarch64 and qcow (BIOS) on x86_64.
  qemuUefiBoot = vm: vm.type != "Windows" && vmArch vm == "aarch64";

  # UTM 4.x QEMU-backend plist template.  Indented strings in Nix strip the
  # common leading whitespace (6 spaces here), producing a 0-based document.
  mkConfigPlist =
    vm:
    builtins.replaceStrings
      [
        "__VM_NAME__"
        "__VM_DISPLAY__"
        "__VM_DISPLAY_CARD__"
        "__VM_DIR_SHARE_MODE__"
        "__VM_UUID__"
        "__VM_MAC_ADDRESS__"
        "__VM_ARCH__"
        "__VM_CPUS__"
        "__VM_RAM_MB__"
        "__VM_MACHINE__"
        "__VM_HYPERVISOR__"
        "__VM_UEFI_BOOT__"
      ]
      [
        vm.name
        vm.display
        (displayCard vm)
        (directoryShareMode vm)
        (mkUuid vm.name)
        (mkMacAddress vm.name)
        (vmArch vm)
        (toString vm.cpus)
        (toString ((vm.ramBytes + 524288) / 1048576))
        (vmMachine vm)
        (if qemuHypervisor vm then "<true/>" else "<false/>")
        (if qemuUefiBoot vm then "<true/>" else "<false/>")
      ]
      # Method 4 (runtime direct read — builtins.readFile embeds at eval time)
      (builtins.readFile ../../modules/configs/vms/utm-config.plist.xml);
in
{
  # Write a UTM config.plist template for each VM declared in VMs.json.
  # vm-setup.sh copies the appropriate template into the UTM bundle at
  # provisioning time so PlistBuddy is no longer needed at runtime.
  home.file = builtins.listToAttrs (
    builtins.map (vm: {
      name = ".local/share/nucleus/vms/${vm.name}-config.plist";
      value = {
        text = mkConfigPlist vm;
      };
    }) enabledVms
  );
}
