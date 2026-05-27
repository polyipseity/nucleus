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
{ config, pkgs, ... }:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/VMs.json);

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

  # QEMU display card appropriate for the guest OS and host arch.
  # Windows VMs use vga for broadest driver coverage.
  # Linux/NixOS VMs use virtio variants for best performance.
  displayCard =
    vm:
    if isArm then
      (if vm.type == "Windows" then "vga" else "virtio-ramfb")
    else
      (if vm.type == "Windows" then "vga" else "virtio-gpu-pci");

  # UTM 4.x sharing mode selector.
  # Modern UTM uses DirectoryShareMode/DirectoryShareReadOnly (not the legacy
  # DirectorySharing/ReadOnlySharing keys).  We emit webdav when sharing is
  # requested and none otherwise; users still choose the host path in UTM UI.
  directoryShareMode =
    vm: if vm.shareDevDir then "<string>webdav</string>" else "<string>none</string>";

  # Match firmware mode to the guest image build contract:
  # - Windows images are built BIOS/MBR (Autounattend.xml), so disable UEFI.
  # - NixOS images are qcow-efi on aarch64 and qcow (BIOS) on x86_64.
  qemuUefiBoot = vm: vm.type != "Windows" && vmArch vm == "aarch64";

  # UTM 4.x QEMU-backend plist template.  Indented strings in Nix strip the
  # common leading whitespace (6 spaces here), producing a 0-based document.
  mkConfigPlist = vm: ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Backend</key>
        <string>QEMU</string>
        <key>ConfigurationVersion</key>
        <integer>4</integer>
        <key>Drive</key>
        <array>
            <dict>
                <key>Identifier</key>
                <string>${vm.name}-disk-main</string>
                <key>ImageName</key>
                <string>disk-main.qcow2</string>
                <key>ImageType</key>
                <string>Disk</string>
                <key>Interface</key>
                <string>virtio</string>
                <key>ReadOnly</key>
                <false/>
            </dict>
        </array>
        <key>Display</key>
        <array>
            <dict>
                <key>Hardware</key>
                <string>${displayCard vm}</string>
                <key>DynamicResolution</key>
                <true/>
                <key>UpscalingFilter</key>
                <string>nearest</string>
                <key>DownscalingFilter</key>
                <string>linear</string>
                <key>NativeResolution</key>
                <false/>
            </dict>
        </array>
        <key>Information</key>
        <dict>
            <key>Icon</key>
            <string>generic</string>
            <key>Name</key>
            <string>${vm.display}</string>
            <key>UUID</key>
            <string>${mkUuid vm.name}</string>
        </dict>
        <key>Network</key>
        <array>
            <dict>
                <key>Hardware</key>
                <string>virtio-net-pci</string>
                <key>Mode</key>
                <string>Shared</string>
                <key>PortForward</key>
                <array/>
            </dict>
        </array>
        <key>Serial</key>
        <array/>
        <key>Sharing</key>
        <dict>
            <key>ClipboardSharing</key>
            <true/>
          <key>DirectoryShareMode</key>
          ${directoryShareMode vm}
          <key>DirectoryShareReadOnly</key>
            <false/>
        </dict>
        <key>Sound</key>
        <array>
            <dict>
                <key>Hardware</key>
                <string>intel-hda</string>
            </dict>
        </array>
        <key>QEMU</key>
        <dict>
            <key>AdditionalArguments</key>
            <array/>
            <key>BalloonDevice</key>
            <false/>
            <key>DebugLog</key>
            <false/>
            <key>Hypervisor</key>
            ${if qemuHypervisor vm then "<true/>" else "<false/>"}
            <key>PS2Controller</key>
            <false/>
            <key>RTCLocalTime</key>
            <false/>
            <key>RNGDevice</key>
            <true/>
            <key>TPMDevice</key>
            <false/>
            <key>UEFIBoot</key>
            ${if qemuUefiBoot vm then "<true/>" else "<false/>"}
        </dict>
        <key>Input</key>
        <dict>
            <key>MaximumUsbShare</key>
            <integer>3</integer>
            <key>UsbBusSupport</key>
            <string>3.0</string>
            <key>UsbSharing</key>
            <false/>
        </dict>
        <key>System</key>
        <dict>
            <key>Architecture</key>
            <string>${vmArch vm}</string>
            <key>CPU</key>
            <string>default</string>
            <key>CPUCount</key>
            <integer>${toString vm.cpus}</integer>
            <key>CPUFlagsAdd</key>
            <array/>
            <key>CPUFlagsRemove</key>
            <array/>
            <key>ForceMulticore</key>
            <false/>
            <key>JITCacheSize</key>
            <integer>0</integer>
            <key>MemorySize</key>
            <integer>${toString ((vm.ramBytes + 524288) / 1048576)}</integer>
            <key>Target</key>
            <string>${vmMachine vm}</string>
        </dict>
    </dict>
    </plist>
  '';
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
    }) vmsData.VMs
  );
}
