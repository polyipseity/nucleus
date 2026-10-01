# NixOS/vms.nix - KVM/libvirt virtual machine infrastructure for the NixOS host.
# Guests are declared in src/modules/vms/VMs.json and provisioned by
# scripts/vm.sh (`nucleus-vm setup`).  Disk images live under
# ~/virtual machines/{data,src}/ in QCOW2, which copies to UTM (macOS) and QEMU
# (Windows) without conversion; the tree is local-only and excluded from cloud
# sync.  VirtioFS (virtiofsd) shares ~/dev with Linux guests, mounted at
# /home/<user>/dev inside the VM.  Domain XML is generated at Nix evaluation
# time and installed to /var/lib/nucleus/vms/<name>-domain.xml (the nucleus
# SYSTEM root) so vm.sh can call virsh define without inlining the XML.
{
  lib,
  pkgs,
  username,
  ...
}:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/vms/VMs.json);
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

  # Optional VirtioFS element appended after <channel>.  The leading \n keeps it
  # on its own line at the surrounding 4-space indent of the XML template.
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

  # Android disk attachments for GSI images.  The system disk is the writable
  # data/<id> (system).qcow2 overlay over src/Android/system image.qcow2, which
  # stays pristine; userdata is a writable qcow2; the GSI image attaches
  # read-only only when the Android group's gsiUrl is set.  Filenames come from
  # the manifest Android group, so VMs.json stays canonical.
  androidDisks =
    vm:
    if vm.type != "Android" then
      ""
    else
      "<disk type='file' device='disk'>\n"
      + "      <driver name='qemu' type='qcow2'/>\n"
      + "      <source file='${vmDir}/data/${vm.id} (system).qcow2'/>\n"
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
        + "      <source file='${vmDir}/src/Android/${vm.Android.gsiImage}'/>\n"
        + "      <target dev='vdc' bus='virtio'/>\n"
        + "      <readonly/>\n"
        + "    </disk>"
      );

  # Firmware block: UEFI for Android, legacy BIOS otherwise.  GSI boot needs
  # AArch64 UEFI via AAVMF; other guests take the standard hvm type with the
  # host-appropriate arch and machine.
  vmFirmware =
    vm:
    if vm.type == "Android" then
      "<os firmware='efi'>\n"
      + "    <type arch='aarch64' machine='virt'>hvm</type>\n"
      + "    <loader type='pflash' readonly='yes' secure='no'>/usr/share/AAVMF/AAVMF_CODE.secboot.fd</loader>\n"
      # WHY: <nvram> is a template path: libvirt creates a per-domain
      # writable NVRAM copy and preserves it across defines and reboots, so UEFI
      # vars stay per-VM without our own data/ copy.
      + "    <nvram>/usr/share/AAVMF/AAVMF_VARS.fd</nvram>\n"
      + "    <boot dev='hd'/>\n"
      + "  </os>"
    else
      "<os>\n"
      + "    <type arch='${vmArch vm}' machine='${vmMachine vm}'>hvm</type>\n"
      + "    <boot dev='hd'/>\n"
      + "  </os>";

  # USB tablet gives Android absolute pointer coordinates; the default emulated
  # mouse is imprecise.
  androidInput = vm: if vm.type != "Android" then "" else "<input type='tablet' bus='usb'/>";

  androidSound = vm: if vm.type != "Android" then "" else "<sound model='ac97'/>";

  # passt ranges come from the manifest portForwards, so the XML matches
  # VMs.json (host ports 22000-22099).
  portForwardRanges =
    vm:
    lib.concatMapStrings (pf: ''
      <portForward proto='tcp'>
        <range start='${toString pf.hostPort}' to='${toString pf.guestPort}'/>
      </portForward>
    '') vm.portForwards;

  # User-mode network with a passt backend, replacing the libvirt NAT network.
  networkInterface =
    vm:
    "<interface type='user'>\n"
    + "      <backend type='passt'/>\n"
    + "      <model type='virtio'/>\n"
    + (portForwardRanges vm)
    + "    </interface>";

  # The Nix indented string strips the common leading whitespace, producing a
  # 0-based XML document.
  mkDomainXml =
    vm:
    builtins.replaceStrings
      [
        "__VM_ID__"
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
      (builtins.readFile ../../modules/vms/nixos-domain.xml);

  # Each VM's domain XML, generated into the nix store for activation to install
  # to the SYSTEM root.  Keyed by VM id.
  vmXmlFiles = lib.listToAttrs (
    builtins.map (
      vm: lib.nameValuePair vm.id (pkgs.writeText "nucleus-${vm.id}-domain.xml" (mkDomainXml vm))
    ) enabledVms
  );
in
{
  # KVM-accelerated QEMU through the libvirt management API.  runAsRoot = false
  # runs the QEMU child as the calling user, which is safer and enough for
  # unprivileged KVM access.
  # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.enable
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      # KVM-optimised build; TCG is stripped because it goes unused here.
      # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.qemu.package
      package = pkgs.qemu_kvm;
      # Run the per-user QEMU process as the calling user, not root.
      # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.qemu.runAsRoot
      runAsRoot = false;
      # swtpm emulates the TPM 2.0 chip Windows 11 needs.
      # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.qemu.swtpm.enable
      swtpm.enable = true;
    };
  };

  # SPICE USB redirection forwards host USB devices into a running guest.
  # Source: https://mynixos.com/nixpkgs/option/virtualisation.spiceUSBRedirection.enable
  virtualisation.spiceUSBRedirection.enable = true;

  # kvm gates /dev/kvm access for hardware acceleration; libvirtd gates
  # unprivileged virsh and virt-manager on the system-level socket.
  # Source: https://mynixos.com/nixpkgs/option/users.users
  users.users.${username}.extraGroups = lib.mkAfter [
    "kvm"
    "libvirtd"
  ];

  # VM management and disk provisioning tools.
  # Source: https://mynixos.com/nixpkgs/option/environment.systemPackages
  environment.systemPackages = with pkgs; [
    passt
    qemu_kvm
    virt-manager
    virt-viewer
    virtiofsd
  ];

  # Install the domain XML so vm.sh can call `virsh define` on it.
  # environment.etc always nests under /etc, so a system activation script writes
  # to the SYSTEM root (mode 0444, readable by all).
  # Source: https://mynixos.com/nixpkgs/option/system.activationScripts
  system.activationScripts.nixos-vms-xml = lib.mkBefore ''
    install -d -m 0755 /var/lib/nucleus/vms
    ${lib.concatStringsSep "\n" (
      builtins.map (
        vm: "install -D -m 0444 '${vmXmlFiles.${vm.id}}' '/var/lib/nucleus/vms/${vm.id}-domain.xml'"
      ) enabledVms
    )}
  '';

  # Disk-image base under the excluded `virtual machines` tree (item 3), which is
  # user-intended rather than a nucleus root and stays out of cloud sync.
  systemd.tmpfiles.rules = lib.mkAfter [
    "d ${homeDir}/virtual machines/data 0755 ${username} users -"
    "d ${homeDir}/virtual machines/src 0755 ${username} users -"
  ];
}
