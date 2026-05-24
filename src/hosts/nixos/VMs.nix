# nixos/vms.nix — KVM/libvirt virtual machine infrastructure for the NixOS host.
#
# Enables the libvirtd hypervisor so QEMU/KVM guests can be managed via virsh
# and virt-manager.  Guest VMs are declared in src/modules/VMs.json and
# provisioned by scripts/VM-setup.sh (run via `nucleus-VM-setup`).
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
# /etc/nucleus/vms/<name>-domain.xml so VM-setup.sh can call virsh define
# without needing to inline the XML at provisioning time.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  vmsData = builtins.fromJSON (builtins.readFile ../../modules/VMs.json);

  isArm = pkgs.stdenv.hostPlatform.isAarch64;
  arch = if isArm then "aarch64" else "x86_64";
  machine = if isArm then "virt" else "q35";
  emulator = "${pkgs.qemu_kvm}/bin/qemu-system-${arch}";
  homeDir = "/home/${username}";
  vmDir = "${homeDir}/virtual machines";

  videoModel = vm: if vm.type == "windows" then "vga" else "virtio";

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

  # Libvirt domain XML template.  Indented strings in Nix strip the common
  # leading whitespace (6 spaces here), producing a 0-based XML document.
  mkDomainXml = vm: ''
    <domain type='kvm'>
      <name>${vm.name}</name>
      <title>${vm.display}</title>
      <memory unit='MiB'>${toString vm.ramMiB}</memory>
      <vcpu>${toString vm.cpus}</vcpu>
      <os>
        <type arch='${arch}' machine='${machine}'>hvm</type>
        <boot dev='hd'/>
      </os>
      <cpu mode='host-passthrough'/>
      <features>
        <acpi/>
        <apic/>
      </features>
      <devices>
        <emulator>${emulator}</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='${vmDir}/${vm.name}.qcow2'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        <interface type='network'>
          <source network='default'/>
          <model type='virtio'/>
        </interface>
        <video>
          <model type='${videoModel vm}'/>
        </video>
        <graphics type='spice' autoport='yes'>
          <listen type='address'/>
          <image compression='off'/>
        </graphics>
        <channel type='spicevmc'>
          <target type='virtio' name='com.redhat.spice.0'/>
        </channel>${virtiofsDev vm}
        <memballoon model='virtio'/>
        <rng model='virtio'>
          <backend model='random'>/dev/urandom</backend>
        </rng>
      </devices>
    </domain>
  '';
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
  # Source: https://mynixos.com/nixpkgs/option/environment.systemPackages
  environment.systemPackages = with pkgs; [
    qemu_kvm
    virt-manager
    virt-viewer
    virtiofsd
  ];

  # Pre-generate libvirt domain XML for each declared VM so VM-setup.sh can
  # call `virsh define /etc/nucleus/vms/<name>-domain.xml` without needing to
  # inline or template the XML at provisioning time.  Files are mode 444
  # (readable by all) so the regular user can pass them to virsh define.
  # Source: https://mynixos.com/nixpkgs/option/environment.etc
  environment.etc = lib.listToAttrs (
    builtins.map (
      vm: lib.nameValuePair "nucleus/vms/${vm.name}-domain.xml" { text = mkDomainXml vm; }
    ) vmsData.VMs
  );
}
