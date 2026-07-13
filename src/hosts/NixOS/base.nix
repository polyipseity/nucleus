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

  # All-process environment variables.
  # NixOS `environment.variables` propagates to all processes (shell, GUI login
  # manager, systemd user services) via PAM and systemd.  Home Manager's
  # `home.sessionVariables` only affects shell sessions, so all-process vars
  # must be here.
  environment.variables = {
    # Identify this host for VM host-scoping and other host-aware consumers.
    NUCLEUS_HOST = "NixOS";

    # Preferred editors for shell and GUI tools.
    EDITOR = "nvim";
    VISUAL = "nvim";

    # Point clients at the LiteLLM proxy instead of Ollama directly.
    OLLAMA_HOST = "127.0.0.1:4000";

    # Disable OpenCode auto-update globally to avoid version skew.
    OPENCODE_DISABLE_AUTOUPDATE = "true";

    # Password-store routing for pass, QtPass, and gopass.
    PASSWORD_STORE_DIR = "/home/polyipseity/dev/monorepo-private/self/passwords";
    GOPASS_CONFIG_COUNT = "1";
    GOPASS_CONFIG_KEY_1 = "path";
    GOPASS_CONFIG_VALUE_1 = "/home/polyipseity/dev/monorepo-private/self/passwords";

    # Fallback toolchain for unmanaged projects outside Nix devShells.
    NUCLEUS_DEFAULT_DEV_BIN = "${
      pkgs.symlinkJoin {
        name = "default-dev-tools";
        paths = [
          pkgs.bun
          pkgs.prek
          pkgs.uv
        ];
      }
    }/bin";
    NUCLEUS_DEFAULT_DEV_ENV = "1";

    # Starship prompt paths — explicit for cross-host uniformity.
    STARSHIP_CACHE = "/home/polyipseity/.cache/starship";
    STARSHIP_CONFIG = "/home/polyipseity/.config/starship.toml";
  };

  # Disable nano to prevent its default EDITOR assignment from overriding
  # home-manager's neovim defaultEditor at the system level.
  programs.nano.enable = false;
}
