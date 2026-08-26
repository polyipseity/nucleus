# MacBook/vms.nix — UTM VM configuration templates for the macOS host.
#
# Generates UTM 4.x QEMU-backend config.plist templates for each VM declared in
# src/modules/VMs.json.  Templates are written to
# ~/Library/Application Support/nucleus/vms/<name>-config.plist at Home Manager activation time
# and consumed by scripts/vm.sh (nucleus-vm setup) to create UTM bundles
# without PlistBuddy invocations.
#
# The UUID for each VM is derived deterministically from the VM id via SHA-256
# (src/modules/lib/vm-identity.nix) so re-provisioning from scratch always
# produces the same UTM identity.
#
# Source: https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration.swift
{ pkgs, lib, ... }:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/VMs.json);
  size = import ../../modules/lib/size.nix;
  vmIdentity = import ../../modules/lib/vm-identity.nix;
  nucleusHost = "MacBook";
  enabledVms = builtins.filter (vm: vm.enabled && builtins.elem nucleusHost vm.hosts) vmsData.VMs;

  isArm = pkgs.stdenv.hostPlatform.isAarch64;

  # Windows images in this repository are built as x86_64 QCOW2 artefacts.
  # Keep UTM system architecture aligned with the guest image architecture,
  # not with the host CPU architecture, so Apple Silicon hosts do not try to
  # import x86_64 guest bundles as aarch64 virtual machines.
  vmArch =
    vm:
    if vm.type == "Android" then
      "aarch64"
    else if vm.type == "Windows" then
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

  # QEMU display card appropriate for the guest OS.
  # Linux/NixOS VMs use VirtIO GPU so UTM exposes an active display on both
  # Apple Silicon and Intel hosts.
  #
  # Android display/renderer requirements: see vm-management.instructions.md.
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

  # Bundle ImageNames are guest-agnostic natural-language disk names; the
  # canonical payloads they hard-link to are resolved by vm.sh at
  # provisioning time (userdata overlay under data/, read-only GSI under
  # src/Android/) from the manifest Android group.
  androidDrives =
    vm:
    if vm.type != "Android" then
      ""
    else
      ''
        <dict>
            <key>Identifier</key>
            <string>${vm.id}-disk-userdata</string>
            <key>ImageName</key>
            <string>user data.qcow2</string>
            <key>ImageType</key>
            <string>Disk</string>
            <key>Interface</key>
            <string>VirtIO</string>
            <key>InterfaceVersion</key>
            <integer>1</integer>
            <key>ReadOnly</key>
            <false/>
        </dict>
      ''
      + lib.optionalString ((vm ? Android) && vm.Android.gsiUrl != null) ''
        <dict>
            <key>Identifier</key>
            <string>${vm.id}-disk-gsi</string>
            <key>ImageName</key>
            <string>GSI disk.qcow2</string>
            <key>ImageType</key>
            <string>Disk</string>
            <key>Interface</key>
            <string>VirtIO</string>
            <key>InterfaceVersion</key>
            <integer>1</integer>
            <key>ReadOnly</key>
            <true/>
        </dict>
      '';

  # UTM PortForward entries derived from the manifest portForwards so the
  # plist always matches VMs.json (host ports in the 22000-22099 range).
  portForwardEntries =
    vm:
    lib.concatMapStrings (p: ''
      <dict>
          <key>Protocol</key>
          <string>TCP</string>
          <key>GuestPort</key>
          <integer>${toString p.guestPort}</integer>
          <key>HostPort</key>
          <integer>${toString p.hostPort}</integer>
      </dict>
    '') vm.portForwards;

  # Android disables audio ("none") to avoid SPICE/CoreAudio deadlock; see vm-management.instructions.md.
  vmSound =
    vm:
    if vm.sound == "none" then
      "<array/>"
    else
      ''
        <array>
            <dict>
                <key>Hardware</key>
                <string>intel-hda</string>
            </dict>
        </array>
      '';

  # UTM 4.x QEMU-backend plist template.  Indented strings in Nix strip the
  # common leading whitespace (6 spaces here), producing a 0-based document.
  mkConfigPlist =
    vm:
    builtins.replaceStrings
      [
        "__VM_ID__"
        "__VM_DISPLAY__"
        "__VM_DISPLAY_CARD__"
        "__VM_DIR_SHARE_MODE__"
        "__VM_UUID__"
        "__VM_MAC_ADDRESS__"
        "__VM_ARCH__"
        "__VM_CPUS__"
        "__VM_RAM_BYTES__"
        "__VM_MACHINE__"
        "__VM_HYPERVISOR__"
        "__VM_UEFI_BOOT__"
        "__VM_ANDROID_DRIVES__"
        "__VM_PORT_FORWARDS__"
        "__VM_SOUND__"
        "__VM_MAIN_DRIVE_IMAGE__"
        "__VM_MAIN_DRIVE_READONLY__"
      ]
      [
        vm.id
        vm.name
        (displayCard vm)
        (directoryShareMode vm)
        (vmIdentity.mkUuid vm.id)
        (vmIdentity.mkMacAddress vm.id vm.macAddressPrefix)
        (vmArch vm)
        (toString vm.cpus)
        (toString (size.ceilMib (size.parse vm.ram)))
        (vmMachine vm)
        (if qemuHypervisor vm then "<true/>" else "<false/>")
        (if qemuUefiBoot vm then "<true/>" else "<false/>")
        (androidDrives vm)
        (portForwardEntries vm)
        (vmSound vm)
        # WHY: the guest-visible main disk is always the writable
        # data/<id>.qcow2 overlay (data/<id> (system).qcow2 for Android), so
        # the bundle's main drive entry is never read-only.
        "system disk.qcow2"
        "<false/>"
      ]
      # check-suppress:config-method: method 4 (runtime direct read) -- builtins.readFile embeds at eval time
      (builtins.readFile ../../modules/configs/vms/utm-config.plist.xml);
in
{
  # Write a UTM config.plist template for each VM declared in VMs.json.
  # vm.sh copies the appropriate template into the UTM bundle at
  # provisioning time so PlistBuddy is no longer needed at runtime.
  home.file = builtins.listToAttrs (
    builtins.map (vm: {
      name = "Library/Application Support/nucleus/vms/${vm.id}-config.plist";
      value = {
        text = mkConfigPlist vm;
      };
    }) enabledVms
  );
}
