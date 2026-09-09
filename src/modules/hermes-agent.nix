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
# API keys: declare secrets in your per-user env-secrets.json with
# consumers: ["hermes-agent"] and matching entries in your SOPS file.
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
  upstreamInputs = {
    self = {
      packages = {
        ${pkgs.stdenv.hostPlatform.system}.default =
          hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
      };
    };
  };

  upstreamModule = (import "${hermes-agent}/nix/homeManagerModules.nix") {
    inputs = upstreamInputs;
  };

  # Resolve per-user env-secrets.json via user overlay.
  userSecretsFile = ../../../users + "/${config.home.username}/env-secrets.json";
  defaultSecretsFile = ../users/default/env-secrets.json;
  secretsFile =
    if builtins.pathExists userSecretsFile then userSecretsFile
    else defaultSecretsFile;
  userSecrets = builtins.fromJSON (builtins.readFile secretsFile);

  # Filter secrets by consumer: only keys where consumers contains "hermes-agent".
  hermesSecrets = builtins.filter
    (s: builtins.elem "hermes-agent" s.consumers)
    userSecrets.secrets;

  # Resolve SOPS secret paths for hermes-consumed keys.
  # Each secret's sopsSource determines which SOPS file to read from.
  mkSecretPath = entry:
    let
      sopsPrefix = if entry.sopsSource == "system" then "../secrets/system.yml"
                    else "../secrets/users/${config.home.username}.yml";
    in
    config.sops.secrets.${entry.name}.path;

  hermesSecretPaths = map mkSecretPath hermesSecrets;

  # SOPS file for user-scoped hermes secrets.
  userSopsFile = ../../../secrets/users + "/${config.home.username}.yml";
  hasUserSopsFile = builtins.pathExists userSopsFile;
in
{
  imports = [ upstreamModule ];

  # Assert: if hermes secrets are declared, the user's SOPS file must exist.
  # Catches the common case (file doesn't exist) with a clear message.
  # sops-nix itself catches missing keys within the file at activation time.
  assertions = [{
    assertion = builtins.length hermesSecrets == 0 || hasUserSopsFile;
    message = "hermes-agent: env-secrets.json declares ${toString (builtins.length hermesSecrets)} secret(s) "
      + "but SOPS file src/secrets/users/${config.home.username}.yml does not exist. "
      + "Add matching keys to the SOPS file or remove entries from env-secrets.json.";
  }];

  # Declare SOPS secrets for all hermes-consumed keys.
  sops.secrets = builtins.listToAttrs (map (entry: {
    name = entry.name;
    value = {
      sopsFile = if entry.sopsSource == "system" then ../secrets/system.yml
                  else ../secrets/users + "/${config.home.username}.yml";
      owner = config.home.username;
      mode = "0400";
    };
  }) hermesSecrets);

  # ── Nucleus-level configuration ──────────────────────────────────────

  programs.hermes-agent.enable = lib.mkDefault true;

  services.hermes-agent = {
    enable = lib.mkDefault true;
    gateway.enable =
      if hostName == "MacBook" then
        lib.mkDefault true
      else
        lib.mkDefault false;
    # Wire SOPS-decrypted API key files into the service environment.
    environmentFiles = lib.mkIf (hermesSecretPaths != []) hermesSecretPaths;
  };
}
