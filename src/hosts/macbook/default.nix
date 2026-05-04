# macbook/default.nix — nix-darwin entrypoint for the MacBook host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }:
{
  imports = [
    ../../modules/core.nix
    ../../modules/gnupg.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ./activation.nix
    ./base.nix
    ./defaults.nix
    ./homebrew.nix
    ./manual-installations.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
  ];
}
