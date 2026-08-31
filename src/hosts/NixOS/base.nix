# NixOS/base.nix — Fundamental NixOS settings common to this host.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  # Centralized env var catalog — canonical registry for managed
  # environment variables across all hosts.
  managedPaths = import ../../modules/lib/managed-paths.nix { inherit pkgs; };
  envVars = import ../../modules/lib/env-catalog.nix {
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
  # Keep device firmware update support enabled (parity with the
  # "automatic critical updates" posture on macOS).
  # Source: NixOS fwupd option reference.
  # https://mynixos.com/nixpkgs/option/services.fwupd.enable
  services.fwupd.enable = true;

  # Changing stateVersion after initial installation requires a migration;
  # keep this pinned to the NixOS release used when this host was first built.
  # Source: NixOS stateVersion guidance.
  # https://mynixos.com/nixpkgs/option/system.stateVersion
  system.stateVersion = "24.11";

  # Keep registry generation explicit: the implicit nixpkgs path registry entry
  # points at a store checkout path and currently emits a context warning during
  # options.json generation on flake evaluation.
  # Source: Nix registry option semantics.
  # https://mynixos.com/nixpkgs/option/nix.registry
  nix.registry = lib.mkForce { };

  # Avoid contextless nixpkgs source-path references in /etc/inputrc by
  # materializing the upstream baseline inputrc content into a text-backed
  # derivation instead of linking directly to the nixpkgs source tree path.
  environment.etc."inputrc".text =
    builtins.readFile "${pkgs.path}/nixos/modules/programs/bash/inputrc";

  # All-process environment variables sourced from the centralized env var
  # catalog.  NixOS `environment.variables` propagates to all processes via
  # PAM and systemd.  See src/modules/lib/env-catalog.nix for the canonical list.
  # Merge managed PATH directories (user-scope package manager bin dirs) into
  # the catalog-derived set since PATH's concatenation semantics don't fit the
  # catalog's single-value model.
  # Uses lib.mkBefore for prepend dirs (before system default PATH from other
  # modules) and lib.mkAfter for append dirs (after them), preserving the
  # prepend/append distinction from pathComponents in the catalog.
  environment.variables = envVars.systemVars // {
    PATH = lib.mkMerge [
      (lib.mkBefore (map (p: "/home/${username}/${p}") managedPaths.pathComponents.prepend))
      (lib.mkAfter (map (p: "/home/${username}/${p}") managedPaths.pathComponents.append))
    ];
  };

  # Disable nano to prevent its default EDITOR assignment from overriding
  # home-manager's neovim defaultEditor at the system level.
  programs.nano.enable = false;
}
