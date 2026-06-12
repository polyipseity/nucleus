# NixOS/default.nix — NixOS entrypoint for the generic Linux host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }: {
  # Inject the host manual path into Home Manager at the user layer so the
  # system entrypoint never needs to define a Home Manager-only option.
  home-manager.sharedModules = [ { nucleus.hostManualFile = "src/hosts/NixOS/MANUAL.md"; } ];

  imports = [
    ../../modules/core.nix
    ../../modules/custom-packages.nix
    ../../modules/gnupg.nix
    ../../modules/logging.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ./ai.nix
    ./base.nix
    ./camilladsp.nix
    ./camillagui-backend.nix
    ./desktop.nix
    ./hardware/cpu.nix
    ./hardware/disks.nix
    ./hardware/gpu.nix
    ./jellyfin.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
    ./users.nix
    ./vms.nix
  ];

  # snd-aloop provides virtual ALSA loopback devices for audio capture
  # (CamillaDSP uses hw:Loopback,1 as capture source).
  boot.kernelModules = [ "snd-aloop" ];

  # Journald retention: cap total journal size so disk-bound systemd services
  # (all managed nucleus services on NixOS) don't grow unbounded.
  services.journald.extraConfig = ''
    SystemMaxUse=500M
  '';
}
