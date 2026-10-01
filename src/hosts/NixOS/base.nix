# NixOS/base.nix - Fundamental NixOS settings common to this host.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  managedPaths = import ../../modules/lib/managed-paths.nix { inherit pkgs; };
  envVars = import ../../modules/lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
    hostName = "NixOS";
  };
in
{
  # Parity with the macOS automatic-critical-updates posture.
  # https://mynixos.com/nixpkgs/option/services.fwupd.enable
  services.fwupd.enable = true;

  # Changing stateVersion after the first install needs a migration; keep the
  # release this host was bootstrapped on.
  # https://mynixos.com/nixpkgs/option/system.stateVersion
  system.stateVersion = "24.11";

  # The implicit nixpkgs path registry entry points at a store checkout and emits
  # a context warning while options.json is generated.
  # https://mynixos.com/nixpkgs/option/nix.registry
  nix.registry = lib.mkForce { };

  # Materialize the baseline inputrc instead of linking the nixpkgs source path,
  # which would leave /etc/inputrc with a contextless reference.
  environment.etc."inputrc".text =
    builtins.readFile "${pkgs.path}/nixos/modules/programs/bash/inputrc";

  # PATH does not fit the catalog's single-value model, so the managed
  # directories are merged here, keeping the prepend/append distinction.
  environment.variables = envVars.systemVars // {
    PATH = lib.mkMerge [
      (lib.mkBefore (map (p: "/home/${username}/${p}") managedPaths.pathComponents.prepend))
      (lib.mkAfter (map (p: "/home/${username}/${p}") managedPaths.pathComponents.append))
    ];
  };

  # nano's EDITOR assignment would override the home-manager neovim default.
  programs.nano.enable = false;
}
