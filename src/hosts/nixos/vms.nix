# nixos/vms.nix — KVM/libvirt virtual machine infrastructure for the NixOS host.
#
# Enables the libvirtd hypervisor so QEMU/KVM guests can be managed via virsh
# and virt-manager.  Guest VMs are declared in src/modules/vms.json and
# provisioned by scripts/vm-setup.sh (run via `nucleus-vm-setup`).
#
# Disk images are stored at ~/Virtual Machines/<name>.qcow2 in QCOW2 format,
# enabling copy-based migration to UTM (macOS) or QEMU (Windows) without
# conversion.  The directory is local-only and excluded from cloud sync.
#
# VirtioFS (virtiofsd) provides zero-copy host-directory sharing between the
# NixOS host and Linux guests.  Each guest mounts the shared ~/dev tree at
# /home/<user>/dev inside the VM for seamless cross-host development.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
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
      # OVMF provides UEFI firmware for modern guest OSes (Windows 11, NixOS).
      # Source: https://mynixos.com/nixpkgs/option/virtualisation.libvirtd.qemu.ovmf.enable
      ovmf.enable = true;
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
}
