# macbook/default.nix — nix-darwin entrypoint for the MacBook host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }:
{
  imports = [
    ../../modules/core.nix
    ./activation.nix
    ./base.nix
    ./defaults.nix
    ./homebrew.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
  ];
}
