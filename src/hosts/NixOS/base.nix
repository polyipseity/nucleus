# NixOS/base.nix — Fundamental NixOS settings common to this host.
{ lib, pkgs, ... }: {
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

  # Disable OpenCode auto-update globally to avoid version skew across machines.
  # Updates are controlled via flake updates and managed environment versioning.
  # Source: OpenCode CLI env var table (`OPENCODE_DISABLE_AUTOUPDATE`)
  # https://opencode.ai/docs/zh-tw/cli/#環境變數
  environment.variables.OPENCODE_DISABLE_AUTOUPDATE = "true";

  # Disable nano to prevent its default EDITOR assignment from overriding
  # home-manager's neovim defaultEditor at the system level.
  programs.nano.enable = false;
}
