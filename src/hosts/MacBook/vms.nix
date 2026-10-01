# MacBook/vms.nix - UTM config.plist templates for each VM in VMs.json. vm.sh
# copies them into the UTM bundle, so no PlistBuddy at provisioning time.
# UUIDs derive from the VM id via SHA-256 (vm-identity.nix), so a rebuild
# reproduces the same UTM identity.
# Source: https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration.swift
{ pkgs, lib, ... }:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/vms/VMs.json);
  size = import ../../modules/lib/size.nix;
  vmIdentity = import ../../modules/vms/vm-identity.nix;
  nucleusHost = "MacBook";
  enabledVms = builtins.filter (vm: vm.enabled && builtins.elem nucleusHost vm.hosts) vmsData.VMs;

  isArm = pkgs.stdenv.hostPlatform.isAarch64;

  # Windows images are built as x86_64 QCOW2. Architecture follows the guest
  # image, not the host CPU, so Apple Silicon does not import x86_64 bundles as
  # aarch64.
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

  # HVF cannot accelerate an x86_64 guest on Apple Silicon, and Hypervisor true
  # there fails the import with an invalid accelerator path.
  qemuHypervisor = vm: if isArm then vmArch vm == "aarch64" else true;

  # VirtIO GPU so UTM exposes an active display on Apple Silicon and Intel.
  displayCard = vm: if vm.type == "Windows" then "virtio-vga" else "virtio-gpu-pci";

  # UTM 4.x wants the enum display name (WebDAV/None) under DirectoryShareMode,
  # not the legacy DirectorySharing key with a lowercase value.
  directoryShareMode =
    vm: if vm.shareDevDir then "<string>WebDAV</string>" else "<string>None</string>";

  # Firmware mode follows the guest image build contract: Windows images are
  # BIOS/MBR (Autounattend.xml), NixOS images are qcow-efi on aarch64 and qcow
  # (BIOS) on x86_64.
  qemuUefiBoot = vm: vm.type != "Windows" && vmArch vm == "aarch64";

  # ImageNames are guest-agnostic disk names; vm.sh resolves the payloads they
  # hard-link to from the manifest Android group (userdata overlay under data/,
  # read-only GSI under src/Android/).
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

  # PortForward entries come from the manifest, so the plist always matches
  # VMs.json (host ports in the 22000-22099 range).
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

  # Android disables audio ("none") to avoid the SPICE/CoreAudio deadlock.
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

  # Nix strips the common leading whitespace from indented strings, so the
  # 6-space indent below yields a 0-based document.
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
      (builtins.readFile ../../modules/vms/utm-config.plist.xml);
in
{

  home.file = builtins.listToAttrs (
    builtins.map (vm: {
      name = "Library/Application Support/nucleus/vms/${vm.id}-config.plist";
      value = {
        text = mkConfigPlist vm;
      };
    }) enabledVms
  );
}
