# NixOS entrypoint for the generic Linux host.
{ ... }: {
  home-manager.sharedModules = [ ./services.nix ];

  imports = [
    ../../modules/core.nix
    ../../modules/posix
    # WHY: security.sudo is a NixOS-only option, so the macOS-shared posix/
    # aggregator cannot carry it; the host imports the module directly.
    ../../modules/posix/security.nix
    ../../modules/https-proxy.nix
    ../../modules/redis.nix
    ../../modules/camillagui-backend.nix
    ./ai.nix
    ./base.nix
    ./camilladsp.nix
    ./camillagui-backend.nix
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

  # WHY: this closes the chain an application sees. The application opens the ALSA
  # default, which is the loopback playback side; CamillaDSP captures the loopback
  # capture side and plays to the real card. `type plug` resamples, so an
  # application may open the default at any rate while the configs capture at
  # 44100. Consequence: with camilladsp stopped nothing drains the loopback, so
  # output is silent.
  # check-suppress:config-method: method 2 (read-only) -- environment.etc is the
  # declarative /etc deployment and takes build-time content only, so a writable
  # symlink cannot be expressed there; ALSA clients open this as root, outside the
  # user tree the repo is provisioned into.
  environment.etc."asound.conf".source = ../../modules/configs/asound/asound.conf;

  # Journald retention: cap total journal size so disk-bound systemd services
  # (all managed nucleus services on NixOS) don't grow unbounded.
  services.journald.settings.Journal = {
    SystemMaxUse = "500M";
  };
}
