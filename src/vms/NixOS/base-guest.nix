# src/vms/NixOS/base-guest.nix — Shared NixOS guest configuration for
# nixos-generators type builds.
#
# Builds a development-ready NixOS system suitable for use as a QEMU/KVM or UTM
# VM guest, with full parity to the NixOS host configuration (excluding AI
# models and hypervisor infrastructure).  This is the TYPE-scoped base: it is
# built once per NixOS VM type into the shared read-only system image and
# carries NO per-VM identity (no hostname, no credentials, no SSH keys).
# Per-VM identity lives in src/vms/guests/<id>/guest.nix, which imports this
# file and overrides the generic placeholder user via _module.args; it is
# applied to the per-VM data disk at setup time (see vm_inject_guest).
# Used by scripts/vm.sh on macOS and NixOS hosts via:
#
#   nix run github:nix-community/nixos-generators -- \
#     --format-path ./src/vms/NixOS/formats/qcow-btrfs.nix \  # qcow-efi-btrfs on aarch64 hosts
#     --system x86_64-linux   \  # or aarch64-linux on Apple Silicon
#     --configuration ./src/vms/NixOS/base-guest.nix \
#     -o <output-dir>
#
# On Windows hosts, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1
# uses src/vms/NixOS/packer.pkr.hcl instead, which generates a similar
# configuration inline during a Packer QEMU build.
#
# Do NOT declare fileSystems, boot.loader, or hardware-configuration here:
# nixos-generators format modules inject the correct disk/bootloader setup for
# qcow-btrfs (BIOS/hybrid) and qcow-efi-btrfs (UEFI + Btrfs root).
#
# Excludes:
# - src/hosts/NixOS/ai.nix — no AI models inside VMs
# - src/hosts/NixOS/vms.nix — no hypervisor/nested VM support needed
# - src/hosts/NixOS/hardware/* — qemu-guest.nix handles virtualized hardware
# - src/hosts/NixOS/jellyfin.nix — singleton media server not guest-appropriate
# - posix-sops.nix / hosts/NixOS/sops.nix — sops.* options need the sops-nix
#   module, which nixos-generators does not load; the guest takes credentials
#   from NUCLEUS_VM_GUEST_* environment variables instead of SOPS.
#
# Source: https://github.com/nix-community/nixos-generators
{
  modulesPath,
  lib,
  pkgs,
  username,
  ...
}:
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    # WHY: relative to src/vms/NixOS/, repo files are three levels up (../../../src).
    # Shared POSIX modules from src/modules/
    ../../../src/modules/core.nix
    ../../../src/modules/gnupg.nix
    ../../../src/modules/posix-base.nix
    ../../../src/modules/posix-security.nix
    ../../../src/modules/posix-user-shell.nix
    # NixOS host modules (excluding vms, hardware, ai, jellyfin infrastructure)
    ../../../src/hosts/NixOS/base.nix
    ../../../src/hosts/NixOS/desktop.nix
    ../../../src/hosts/NixOS/networking.nix
    ../../../src/hosts/NixOS/security.nix
    ../../../src/hosts/NixOS/users.nix
  ];

  # WHY: posix-base.nix selects its per-host gitconfig via hostName and the
  # shared user modules key off username; nixos-generators passes no
  # specialArgs, so thread generic placeholders here.  This is the TYPE build
  # (no per-VM identity): the per-VM delta src/vms/guests/<id>/guest.nix
  # overrides both with the real values from NUCLEUS_VM_GUEST_* environment
  # variables via the same _module.args option.  SOPS modules (posix-sops.nix,
  # hosts/NixOS/sops.nix) are deliberately NOT imported: they define the
  # sops.* options that only exist when sops-nix.nixosModules.sops is loaded,
  # which nixos-generators does not do for standalone guest builds.  The
  # guest injects its credentials and hostname via NUCLEUS_VM_GUEST_*
  # environment variables instead of SOPS decryption.
  _module.args = {
    # WHY: posix-base.nix and other shared modules now take `repoRoot` as a
    # module arg (threaded via specialArgs on the real hosts). nixos-generators
    # passes no specialArgs, so inject the repo root here. The guest image is
    # built from the repo tree, so the repo root is the parent of src/.
    repoRoot = ../..;
    hostName = lib.mkDefault "nixos";
    username = lib.mkDefault "nixos";
  };

  # VirtioFS sharing is configured after first boot when the host actually
  # exposes a shared directory. Do not force virtio_fs into the initrd here:
  # current aarch64 guest kernels may not ship it as a standalone module, which
  # breaks image generation before the VM ever boots.
  # Example guest-side mount after first boot:
  #   fileSystems."/home/<guest-user>/dev" = { device = "dev"; fsType = "virtiofs"; };

  services.qemuGuest.enable = true;
  services.openssh.enable = true;

  # WHY: hosts/NixOS/security.nix enables the standalone programs.ssh agent;
  # GNOME's gcr-ssh-agent (default-on via gnome-keyring) asserts against it.
  # Keep security.nix's agent and drop gcr's duplicate to satisfy the assertion.
  services.gnome.gcr-ssh-agent.enable = lib.mkForce false;

  # WHY: desktop.nix enables Steam, but Steam and its 32-bit Mesa/Vulkan
  # drivers are x86_64-only.  nixpkgs asserts that hardware.graphics.enable32Bit
  # cannot be set on aarch64 and steam.meta.available is false there, so the
  # aarch64 guest must force both off while keeping the rest of desktop parity.
  hardware.graphics.enable32Bit = lib.mkForce false;
  programs.steam.enable = lib.mkForce false;

  # WHY: desktop.nix installs parsec-bin (unfree remote-desktop client) and the
  # real host allows unfree packages via mkPkgs' config.allowUnfree; the
  # standalone nixos-generators evaluation does not set that, so refuse the
  # package.  Mirror the host's allowUnfree policy through nixpkgs.config the
  # standard NixOS way instead of dropping the package from the desktop set.
  # .NET 6 is EOL upstream; the real host pins it (permittedInsecurePackages in
  # mkPkgs) for EIDE/runtime compatibility, so the guest mirrors that too.
  nixpkgs.config = {
    allowUnfree = true;
    permittedInsecurePackages = [ "dotnet-runtime-6.0.36" ];
  };

  # WHY: converge the guest to the latest flake-defined state after boot.  The
  # service is user-scoped; the generic `username` arg resolves to the real
  # per-VM user at injection time (per-VM guest.nix overrides _module.args).
  systemd.services.nucleus-rebuild =
    let
      flakeDir = "/home/${username}/dev/nucleus/src";
    in
    {
      description = "Rebuild NixOS system from nucleus flake";
      wantedBy = [ ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = username;
        Group = "users";
        Environment = "HOME=/home/${username}";
      };
      script = ''
        ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake ${flakeDir}#NixOS
      '';
    };

  # WHY: hosts/NixOS/base.nix pins system.stateVersion to the real host's
  # "24.11"; this guest image is built fresh from nixos-generators against the
  # pinned nixpkgs, so force the guest's newer stateVersion instead of letting
  # the two plain definitions collide.
  system.stateVersion = lib.mkForce "25.05";
}
