# MacBook/vms.nix — UTM VM configuration templates for the macOS host.
#
# Generates UTM 4.x QEMU-backend config.plist templates for each VM declared in
# src/modules/VMs.json.  Templates are written to
# ~/.local/share/nucleus/vms/<name>-config.plist at Home Manager activation time
# and consumed by scripts/vm.sh (nucleus-vm setup) to create UTM bundles
# without PlistBuddy invocations.
#
# The UUID for each VM is derived deterministically from the VM name via SHA-256
# so re-provisioning from scratch always produces the same UTM identity.
#
# Source: https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration.swift
{ pkgs, lib, ... }:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/VMs.json);
  size = import ../../modules/lib/size.nix;
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

  # Derive a deterministic UUID from the VM name (format: 8-4-4-4-12 hex).
  # The same name always maps to the same UUID so re-provisioning the same VM
  # produces a stable UTM identity across apply runs.
  mkUuid =
    name:
    let
      h = builtins.hashString "sha256" name;
    in
    "${builtins.substring 0 8 h}-${builtins.substring 8 4 h}-${builtins.substring 12 4 h}-${builtins.substring 16 4 h}-${builtins.substring 20 12 h}";

  # Deterministic locally-administered unicast MAC per VM name, with the
  # prefix taken from the manifest's macAddressPrefix field.
  mkMacAddress =
    name: prefix:
    let
      h = builtins.hashString "sha256" "mac:${name}";
    in
    "${prefix}:${builtins.substring 0 2 h}:${builtins.substring 2 2 h}:${builtins.substring 4 2 h}:${builtins.substring 6 2 h}:${builtins.substring 8 2 h}";

  # QEMU display card appropriate for the guest OS.
  # Linux/NixOS VMs use VirtIO GPU so UTM exposes an active display on both
  # Apple Silicon and Intel hosts.
  #
  # Android (LineageOS) on UTM additionally requires UTM's global
  # "Renderer backend" (pref QEMURendererBackend) to be Apple Core OpenGL
  # (CGL), value 3; ANGLE (Metal) makes the UI not appear after boot
  # (LineageOS wiki).  CGL is the native macOS GL backend introduced in UTM
  # 5.x (kQEMURendererBackendCGL).  Note the recurring "display freezes
  # randomly" bug is renderer-orthogonal -- a client-side SPICE
  # display-channel stall in UTM's SPICE client (UTM #2221, CocoaSpice#5), so
  # CGL does not prevent freezes; UTM 5.0.4 SPICE renderer fixes and keeping
  # the VM window visible are the mitigations.  See
  # .agents/instructions/utm-android-freeze.instructions.md.  The pref is
  # provisioned automatically by macos-set-utm-renderer.sh via activation.nix,
  # so no manual UTM settings change is needed.
  # ref: https://github.com/utmapp/UTM/blob/v5.0.3/Services/UTMQemuSystemBackends.h -- kQEMURendererBackendCGL = 3
  # ref: https://wiki.lineageos.org/libvirt-qemu.html -- Android UI renderer guidance
  # ref: https://github.com/utmapp/UTM/issues/2221 -- "Display freezes randomly"; renderer-orthogonal SPICE stall
  # ref: https://github.com/utmapp/UTM/issues/378 -- historic Android VM freeze reports
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
            <string>android-userdata.qcow2</string>
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
            <string>android-gsi.img</string>
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

  # Base SSH forward (guest 22) for non-Android VMs, derived from the
  # manifest portForwards so the plist always matches VMs.json.  Android
  # guests expose ADB and SSH on forwarded ports 5555/5554 instead, and must
  # NOT also claim host 2222: when Android and NixOS run together the second
  # VM would fail to start ("Could not set up host forwarding rule") because
  # host port 2222 is already taken by the first.
  basePortForward =
    vm:
    if vm.type == "Android" then
      ""
    else
      lib.concatMapStrings (p: ''
        <dict>
            <key>Protocol</key>
            <string>TCP</string>
            <key>GuestPort</key>
            <integer>${toString p.guestPort}</integer>
            <key>HostPort</key>
            <integer>${toString p.hostPort}</integer>
        </dict>
      '') (builtins.filter (p: p.guestPort == 22) vm.portForwards);

  additionalPortForwards =
    vm:
    if vm.type != "Android" then
      ""
    else
      lib.concatMapStrings (p: ''
        <dict>
            <key>Protocol</key>
            <string>TCP</string>
            <key>GuestPort</key>
            <integer>${toString p.guestPort}</integer>
            <key>HostPort</key>
            <integer>${toString p.hostPort}</integer>
        </dict>
      '') (builtins.filter (p: p.guestPort != 22) vm.portForwards);

  # Guest audio hardware per VM.  Android disables audio ("none" -> empty
  # Sound array): the SPICE audio pipeline teardown deadlocks UTM's SPICE
  # Main Loop against the CoreAudio IO thread, freezing the display.  No
  # upstream UTM fix exists as of 5.0.4, so the workaround stays until one
  # lands.  Any other value (or an absent field) keeps the intel-hda sound
  # card for the other guests.
  # ref: .agents/instructions/utm-android-freeze.instructions.md
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
        "__VM_NAME__"
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
        "__VM_BASE_PORT_FORWARD__"
        "__VM_ADDITIONAL_PORT_FORWARDS__"
        "__VM_SOUND__"
      ]
      [
        vm.id
        vm.name
        (displayCard vm)
        (directoryShareMode vm)
        (mkUuid vm.id)
        (mkMacAddress vm.id vm.macAddressPrefix)
        (vmArch vm)
        (toString vm.cpus)
        (toString (size.ceilMib (size.parse vm.ram)))
        (vmMachine vm)
        (if qemuHypervisor vm then "<true/>" else "<false/>")
        (if qemuUefiBoot vm then "<true/>" else "<false/>")
        (androidDrives vm)
        (basePortForward vm)
        (additionalPortForwards vm)
        (vmSound vm)
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
      name = ".local/share/nucleus/vms/${vm.id}-config.plist";
      value = {
        text = mkConfigPlist vm;
      };
    }) enabledVms
  );
}
