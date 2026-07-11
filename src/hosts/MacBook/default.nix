# nix-darwin entrypoint for the MacBook host.
{ ... }: {
  # Inject the host manual path into Home Manager at the user layer so the
  # system entrypoint never needs to define a Home Manager-only option.
  # vms.nix generates UTM config.plist templates for each VM in VMs.json.
  home-manager.sharedModules = [
    ../../modules/iterm2.nix
    ./cloud-drives.nix
    ./services.nix
    ./vms.nix
  ];

  imports = [
    ../../modules/core.nix
    ../../modules/gnupg.nix
    ../../modules/https-proxy.nix
    ../../modules/logging.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ./activation.nix
    ./ai.nix
    ./base.nix
    ./camilladsp.nix
    ./camillagui-backend.nix
    ../../modules/camillagui-backend.nix
    ./defaults.nix
    ./homebrew.nix
    ./https-proxy.nix
    ../../modules/https-proxy.nix
    ./jellyfin.nix
    ./linux-builder.nix
    ./manual-installations.nix
    ./networking.nix
    ./ntfs-3g.nix
    ./security.nix
    ./sops.nix
    ./service-watchdog.nix
  ];
}
