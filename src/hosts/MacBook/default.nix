# nix-darwin entrypoint for the MacBook host.
{ ... }: {
  # Inject the host manual path into Home Manager at the user layer so the
  # system entrypoint never needs to define a Home Manager-only option.
  # vms.nix generates UTM config.plist templates for each VM in VMs.json.
  home-manager.sharedModules = [
    ../../modules/iterm2.nix
    ./cloud-drives.nix
    ./services
    ./vms.nix
  ];

  imports = [
    ../../modules/core.nix
    ../../modules/posix
    ../../modules/https-proxy.nix
    ../../modules/redis.nix
    ../../modules/camillagui-backend.nix
    ./activation.nix
    ./ai.nix
    ./base.nix
    ./camilladsp.nix
    ./camillagui-backend.nix
    ./defaults.nix
    ./filesystem-scope.nix
    ./homebrew.nix
    ./https-proxy.nix
    ../../modules/https-proxy.nix
    ./jellyfin.nix
    ./linux-builder.nix
    ./manual-installations.nix
    ./networking.nix
    ./ntfs-3g.nix
    ./security.nix
    ./service-watchdog.nix
  ];
}
