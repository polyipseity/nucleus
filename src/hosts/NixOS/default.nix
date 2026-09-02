# NixOS entrypoint for the generic Linux host.
{ ... }: {
  home-manager.sharedModules = [ ./services.nix ];

  imports = [
    ../../modules/core.nix
    ../../modules/gnupg.nix
    ../../modules/https-proxy.nix
    ../../modules/logging.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ../../modules/repo-root-file.nix
    ../../modules/agent-host-shell.nix
    ./ai.nix
    ./base.nix
    ./camilladsp.nix
    ./camillagui-backend.nix
    ../../modules/camillagui-backend.nix
    ./desktop.nix
    ./filesystems.nix
    ./hardware/cpu.nix
    ./hardware/disks.nix
    ./hardware/gpu.nix
    ./https-proxy.nix
    ./jellyfin.nix
    ./networking.nix
    ./security.nix
    ./activation.nix
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
