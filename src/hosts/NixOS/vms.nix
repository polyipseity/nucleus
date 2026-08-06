# NixOS/vms.nix — KVM/libvirt virtual machine infrastructure for the NixOS host.
#
# Enables the libvirtd hypervisor so QEMU/KVM guests can be managed via virsh
# and virt-manager.  Guest VMs are declared in src/modules/VMs.json and
# provisioned by scripts/vm.sh (run via `nucleus-vm setup`).
#
# Disk images are stored at ~/virtual machines/<name>.qcow2 in QCOW2 format,
# enabling copy-based migration to UTM (macOS) or QEMU (Windows) without
# conversion.  The directory is local-only and excluded from cloud sync.
#
# VirtioFS (virtiofsd) provides zero-copy host-directory sharing between the
# NixOS host and Linux guests.  Each guest mounts the shared ~/dev tree at
# /home/<user>/dev inside the VM for seamless cross-host development.
#
# Domain XML is generated at Nix evaluation time and installed to
# /etc/nucleus/vms/<name>-domain.xml so vm.sh can call virsh define
# without needing to inline the XML at provisioning time.
{
  lib,
  pkgs,
  username,
  ...
}:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/VMs.json);
  size = import ../../modules/lib/size.nix;
  nucleusHost = "NixOS";
  enabledVms = builtins.filter (vm: vm.enabled && builtins.elem nucleusHost vm.hosts) vmsData.VMs;

  isArm = pkgs.stdenv.hostPlatform.isAarch64;

  vmArch =
    vm:
    if vm.type == "Android" then
      "aarch64"
    else if isArm then
      "aarch64"
    else
      "x86_64";

  vmMachine = vm: if vmArch vm == "x86_64" then "q35" else "virt";

  vmEmulator = vm: "${pkgs.qemu_kvm}/bin/qemu-system-${vmArch vm}";
  homeDir = "/home/${username}";
  vmDir = "${homeDir}/virtual machines";

  videoModel = vm: if vm.type == "Windows" then "vga" else "virtio";

  # Optional VirtioFS filesystem element appended after <channel>.
  # The leading \n keeps it on its own line at 4-space indent (matching the
  # surrounding device elements in the 2-space-indented XML template below).
  virtiofsDev =
    vm:
    if !vm.shareDevDir then
      ""
    else
      "\n    <filesystem type='mount' accessmode='passthrough'>"
      + "\n      <driver type='virtiofs'/>"
      + "\n      <source dir='${homeDir}/dev'/>"
      + "\n      <target dir='dev'/>"
      + "\n    </filesystem>";

  # Android-specific disk attachments for GSI-based Android VM images.
  # system (read-only) and userdata (writable qcow2) are always attached;
  # the GSI image is attached only when the Android group's gsiUrl is set.
  # Image filenames come from the manifest Android group so VMs.json is the
  # single source of truth.
  androidDisks =
    vm:
    if vm.type != "Android" then
      ""
    else
      "<disk type='file' device='disk'>\n"
      + "      <driver name='qemu' type='qcow2'/>\n"
      + "      <source file='${vmDir}/images/${vm.Android.systemImage}'/>\n"
      + "      <target dev='vda' bus='virtio'/>\n"
      + "    </disk>\n"
      + "    <disk type='file' device='disk'>\n"
      + "      <driver name='qemu' type='qcow2'/>\n"
      + "      <source file='${vmDir}/data/${vm.id}.qcow2'/>\n"
      + "      <target dev='vdb' bus='virtio'/>\n"
      + "    </disk>\n"
      + lib.optionalString ((vm ? Android) && vm.Android.gsiUrl != null) (
        "<disk type='file' device='disk'>\n"
        + "      <driver name='qemu' type='raw'/>\n"
        + "      <source file='${vmDir}/images/${vm.Android.gsiImage}'/>\n"
        + "      <target dev='vdc' bus='virtio'/>\n"
        + "      <readonly/>\n"
        + "    </disk>"
      );

  # Firmware block selecting UEFI (Android) or legacy BIOS (non-Android).
  # Android requires AArch64 UEFI via AAVMF for GSI boot; non-Android VMs
  # use the standard hvm type with the host-appropriate arch/machine baked
  # in.
  vmFirmware =
    vm:
    if vm.type == "Android" then
      "<os firmware='efi'>\n"
      + "    <type arch='aarch64' machine='virt'>hvm</type>\n"
      + "    <loader type='pflash' readonly='yes' secure='no'>/usr/share/AAVMF/AAVMF_CODE.secboot.fd</loader>\n"
      + "    <nvram>/usr/share/AAVMF/AAVMF_VARS.fd</nvram>\n"
      + "    <boot dev='hd'/>\n"
      + "  </os>"
    else
      "<os>\n"
      + "    <type arch='${vmArch vm}' machine='${vmMachine vm}'>hvm</type>\n"
      + "    <boot dev='hd'/>\n"
      + "  </os>";

  # USB tablet input device for precise pointer tracking in Android.
  # Android's default emulated mouse is imprecise; a USB tablet provides
  # absolute coordinates matching the display.
  androidInput = vm: if vm.type != "Android" then "" else "<input type='tablet' bus='usb'/>";

  # AC97 sound device for Android VM audio output.
  androidSound = vm: if vm.type != "Android" then "" else "<sound model='ac97'/>";

  # passt port-forward ranges derived from the manifest portForwards so the
  # libvirt domain XML always matches VMs.json (host ports in 22000-22099).
  portForwardRanges =
    vm:
    lib.concatMapStrings (pf: ''
      <portForward proto='tcp'>
        <range start='${toString pf.hostPort}' to='${toString pf.guestPort}'/>
      </portForward>
    '') vm.portForwards;

  # User-mode network interface with passt backend for manifest-driven port
  # forwarding (replaces the default libvirt NAT network).
  networkInterface =
    vm:
    "<interface type='user'>\n"
    + "      <backend type='passt'/>\n"
    + "      <model type='virtio'/>\n"
    + (portForwardRanges vm)
    + "    </interface>";

  # Libvirt domain XML template.  Indented strings in Nix strip the common
  # leading whitespace (6 spaces here), producing a 0-based XML document.
  mkDomainXml =
    vm:
    builtins.replaceStrings
      [
        "__VM_NAME__"
        "__VM_DISPLAY__"
        "__VM_RAM_BYTES__"
        "__VM_CPUS__"
        "__VM_EMULATOR__"
        "__VM_DIR__"
        "__VM_VIDEO_MODEL__"
        "__VM_VIRTIOFS_DEV__"
        "__VM_FIRMWARE__"
        "__VM_ANDROID_DISKS__"
        "__VM_ANDROID_INPUT__"
        "__VM_ANDROID_SOUND__"
        "__VM_NETWORK_INTERFACE__"
      ]
      [
        vm.id
        vm.name
        (toString (size.parse vm.ram))
        (toString vm.cpus)
        (vmEmulator vm)
        vmDir
        (videoModel vm)
        (virtiofsDev vm)
        (vmFirmware vm)
        (androidDisks vm)
        (androidInput vm)
        (androidSound vm)
        (networkInterface vm)
      ]
      # check-suppress:config-method: method 4 (runtime direct read) -- builtins.readFile embeds at eval time
      (builtins.readFile ../../modules/configs/vms/nixos-domain.xml);
in
{
  # Enable KVM-accelerated QEMU virtualisation via the libvirt management API.
  # runAsRoot = false runs the QEMU child process as the calling user rather
  # than root, which is safer and sufficient for unprivileged KVM access.
  # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.enable
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      # Keep QEMU pinned to the KVM-optimised build (strips TCG where unused).
      # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.qemu.package
      package = pkgs.qemu_kvm;
      # Let the per-user QEMU process run as the calling user, not root.
      # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.qemu.runAsRoot
      runAsRoot = false;
      # swtpm emulates a TPM 2.0 chip required by Windows 11 and some secure
      # NixOS setups.
      # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.qemu.swtpm.enable
      swtpm.enable = true;
    };
  };

  # Enable SPICE USB redirection so USB devices plugged into the host can be
  # forwarded into a running guest session.
  # Source: https://mynixos.com/nixpkgs/option/virtualisation.spiceUSBRedirection.enable
  virtualisation.spiceUSBRedirection.enable = true;

  # Add the managed user to the groups that gate KVM and libvirt access.
  #   kvm:      grants direct /dev/kvm device access for hardware acceleration.
  #   libvirtd: grants unprivileged virsh/virt-manager management over the
  #             system-level libvirtd socket.
  # Source: https://mynixos.com/nixpkgs/option/users.users
  users.users.${username}.extraGroups = lib.mkAfter [
    "kvm"
    "libvirtd"
  ];

  # System-level packages needed for VM management and disk provisioning.
  #   virt-manager:  GTK GUI for creating and managing KVM guests.
  #   virt-viewer:   SPICE/VNC client for connecting to guest consoles.
  #   qemu_kvm:      CLI tools including qemu-img for QCOW2 disk management.
  #   virtiofsd:     VirtioFS daemon for zero-copy host→guest directory shares.
  #   passt:         userspace network backend for libvirt user-mode port forwards.
  # Source: https://mynixos.com/nixpkgs/option/environment.systemPackages
  environment.systemPackages = with pkgs; [
    passt
    qemu_kvm
    virt-manager
    virt-viewer
    virtiofsd
  ];

  # Pre-generate libvirt domain XML for each declared VM so vm.sh can
  # call `virsh define /etc/nucleus/vms/<id>-domain.xml` without needing to
  # inline or template the XML at provisioning time.  Files are mode 444
  # (readable by all) so the regular user can pass them to virsh define.
  # Source: https://mynixos.com/nixpkgs/option/environment.etc
  environment.etc = lib.listToAttrs (
    builtins.map (
      vm: lib.nameValuePair "nucleus/vms/${vm.id}-domain.xml" { text = mkDomainXml vm; }
    ) enabledVms
  );
}
