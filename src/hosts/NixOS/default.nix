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

  # WHY: the other half of that loopback now carries the ALSA default, so an
  # application that opens `default` feeds the daemon instead of the card. `type
  # plug` resamples, so an application may open it at any rate while the configs
  # capture at their own. The loopback is one raw PCM with no mixing layer, so a
  # single client holds it at a time; mixing would take `dmix` on top, which is a
  # separate change. Consequence: with camilladsp stopped nothing drains it, so
  # output is silent.
  # check-suppress:config-method: method 2 (read-only) -- a writable link here
  # would be repoRoot-derived, which lands as a store copy that cannot be
  # re-pointed, and every ALSA client on the system has to read this path, which a
  # per-user link cannot guarantee.
  environment.etc."asound.conf".source = ../../modules/configs/asound/asound.conf;

  # Journald retention: cap total journal size so disk-bound systemd services
  # (all managed nucleus services on NixOS) don't grow unbounded.
  services.journald.settings.Journal = {
    SystemMaxUse = "500M";
  };
}
