# MacBook/default.nix — nix-darwin entrypoint for the MacBook host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }: {
  # Inject the host manual path into Home Manager at the user layer so the
  # system entrypoint never needs to define a Home Manager-only option.
  # vms.nix generates UTM config.plist templates for each VM in VMs.json.
  home-manager.sharedModules = [
    ./cloud-drives.nix
    { nucleus.hostManualFile = "src/hosts/MacBook/MANUAL.md"; }
    ./vms.nix
  ];

  imports = [
    ../../modules/core.nix
    ../../modules/custom-packages.nix
    ../../modules/gnupg.nix
    ../../modules/logging.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ./activation.nix
    ./ai.nix
    ./base.nix
    ./defaults.nix
    ./homebrew.nix
    ./jellyfin.nix
    ./linux-builder.nix
    ./manual-installations.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
  ];
}
