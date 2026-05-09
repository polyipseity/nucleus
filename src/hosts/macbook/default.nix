# macbook/default.nix — nix-darwin entrypoint for the MacBook host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }:
{
  # Host-scoped manual checklist consumed by shared Home Manager activation
  # modules. Keep this in the host entrypoint so shared modules never hardcode
  # paths under src/hosts/.
  nucleus.hostManualFile = ./MANUAL.md;

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
