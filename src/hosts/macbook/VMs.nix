# macbook/VMs.nix — UTM VM configuration templates for the macOS host.
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
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/VMs.json);

  isArm = pkgs.stdenv.hostPlatform.isAarch64;
  arch = if isArm then "aarch64" else "x86_64";
  machine = if isArm then "virt" else "q35";

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
      (if vm.type == "windows" then "vga" else "virtio-ramfb-gl")
    else
      (if vm.type == "windows" then "vga" else "virtio-gpu-pci");

  # Optional VirtioFS directory-share keys appended inside <key>Sharing</key>.
  # Leading \n keeps each key on its own line at consistent 12-space indent
  # matching the existing ClipboardShare key in the template below.
  sharingExtra =
    vm:
    if !vm.shareDevDir then
      ""
    else
      "\n            <key>DirectoryReadOnly</key>"
      + "\n            <false/>"
      + "\n            <key>DirectoryShare</key>"
      + "\n            <string>${config.home.homeDirectory}/dev</string>";

  # UTM 4.x QEMU-backend plist template.  Indented strings in Nix strip the
  # common leading whitespace (6 spaces here), producing a 0-based document.
  mkConfigPlist = vm: ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Backend</key>
        <string>qemu</string>
        <key>ConfigurationVersion</key>
        <integer>4</integer>
        <key>Drives</key>
        <array>
            <dict>
                <key>Bootable</key>
                <false/>
                <key>Fixed</key>
                <false/>
                <key>ImagePath</key>
                <string>Images/disk-main.qcow2</string>
                <key>ImageType</key>
                <string>Disk</string>
                <key>Interface</key>
                <string>virtio</string>
                <key>ReadOnly</key>
                <false/>
            </dict>
        </array>
        <key>Display</key>
        <dict>
            <key>Card</key>
            <string>${displayCard vm}</string>
            <key>FitScreen</key>
            <true/>
        </dict>
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
            <key>ClipboardShare</key>
            <true/>${sharingExtra vm}
        </dict>
        <key>Sound</key>
        <array>
            <dict>
                <key>Hardware</key>
                <string>intel-hda</string>
            </dict>
        </array>
        <key>System</key>
        <dict>
            <key>Architecture</key>
            <string>${arch}</string>
            <key>CPU</key>
            <string>default</string>
            <key>CPUCount</key>
            <integer>${toString vm.cpus}</integer>
            <key>CPUFlags</key>
            <array/>
            <key>ForceMulticore</key>
            <false/>
            <key>JITCacheSize</key>
            <integer>0</integer>
            <key>MemorySize</key>
            <integer>${toString vm.ramMiB}</integer>
            <key>Target</key>
            <string>${machine}</string>
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
