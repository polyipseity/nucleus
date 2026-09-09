# src/modules/hermes-agent.nix — Nucleus wrapper for upstream hermes-agent Home Manager module.
#
# Imports the upstream `homeManagerModules.default` with a shimmed `inputs`
# binding so `inputs.self.packages.${system}.default` resolves to the
# hermes-agent package from the overlay (added in flake.nix). The upstream
# module then manages `programs.hermes-agent` (CLI) and
# `services.hermes-agent` (gateway + backend daemons) with platform-native
# service management (launchd on macOS, systemd on Linux).
#
# Per-host overrides (gateway.enable, model defaults) are applied here.
# API keys: add `hermes.ANTHROPIC_API_KEY: "sk-ant-..."` to your
# src/secrets/users/<username>.yml. The secret is materialized by sops-nix
# and passed to the service via environmentFiles.
{
  config,
  lib,
  pkgs,
  hostName,
  hermes-agent,
  ...
}:
let
  # Minimal `inputs` shim for the upstream module.
  # The upstream module accesses `inputs.self.packages.${system}.default`
  # as the default package value for `services.hermes-agent.package`.
  # Our overlay (flake.nix) adds `pkgs.hermes-agent`, so we resolve
  # through the hermes-agent flake's own packages attribute.
  upstreamInputs = {
    self = {
      packages = {
        ${pkgs.stdenv.hostPlatform.system}.default =
          hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
      };
    };
  };

  # Import the upstream module function with our shimmed inputs.
  # The upstream `nix/homeManagerModules.nix` exports a function that
  # receives `inputs` as a parameter and returns a NixOS/HM module.
  upstreamModule = (import "${hermes-agent}/nix/homeManagerModules.nix") {
    inputs = upstreamInputs;
  };

  # Check if the user has a SOPS secrets file. The hermes secret
  # (hermes/env) is declared conditionally — absent when the user
  # hasn't added API keys yet.
  userSecretFile = ../../secrets/users + "/${config.home.username}.yml";
  hasUserSecretFile = builtins.pathExists userSecretFile;
in
{
  imports = [ upstreamModule ];

  # Declare the SOPS secret for hermes API keys.
  # Users must add `hermes.ANTHROPIC_API_KEY: "sk-ant-..."` (or similar)
  # to their src/secrets/users/<username>.yml file.
  sops.secrets = lib.mkIf hasUserSecretFile {
    "hermes/env" = {
      sopsFile = userSecretFile;
      owner = config.home.username;
      mode = "0400";
    };
  };

  # ── Nucleus-level configuration ──────────────────────────────────────

  programs.hermes-agent.enable = lib.mkDefault true;

  services.hermes-agent = {
    enable = lib.mkDefault true;
    # Gateway is opt-in per host. Headless servers (NixOS) don't need it
    # by default; MacBook enables it for messaging integration.
    gateway.enable =
      if hostName == "MacBook" then
        lib.mkDefault true
      else
        lib.mkDefault false;
    # Wire SOPS-decrypted API key file into the service environment.
    # Only present when the user has added hermes secrets to their SOPS file.
    environmentFiles = lib.mkIf hasUserSecretFile [
      config.sops.secrets."hermes/env".path
    ];
  };
}
