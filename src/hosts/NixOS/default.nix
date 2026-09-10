# NixOS entrypoint for the generic Linux host.
{ ... }: {
  home-manager.sharedModules = [ ./services.nix ];

  imports = [
    ../../modules/core.nix
    ../../modules/posix
    ../../modules/https-proxy.nix
    ../../modules/redis.nix
    ../../modules/camillagui-backend.nix
    ./ai.nix
    ./base.nix
    ./camilladsp.nix
    ./camillagui-backend.nix
    ../../modules/audio
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
  services.journald.settings.Journal = {
    SystemMaxUse = "500M";
  };
}
