# src/modules/hermes-agent.nix — Nucleus wrapper for upstream hermes-agent Home Manager module.
#
# Imports the upstream `homeManagerModules.default` HM module directly from
# the flake-parts output. The upstream module manages `programs.hermes-agent`
# (CLI) and `services.hermes-agent` (gateway + backend daemons) with
# platform-native service management (launchd on macOS, systemd on Linux).
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
  sopsUtils = import ./lib/sops-utils.nix;
  inherit (sopsUtils) parseSopsKeys missingSopsKeys;

  # The flake-parts output already binds `inputs` internally —
  # homeManagerModules.default is a standard HM module {config, lib, ...}:
  upstreamModule = hermes-agent.homeManagerModules.default;

  # Resolve per-user env-secrets.json via user overlay.
  userSecretsFile = ../../../users + "/${config.home.username}/env-secrets.json";
  defaultSecretsFile = ../users/default/env-secrets.json;
  secretsFile = if builtins.pathExists userSecretsFile then userSecretsFile else defaultSecretsFile;
  userSecrets = builtins.fromJSON (builtins.readFile secretsFile);

  # Filter secrets by consumer: only keys where consumers contains "hermes-agent".
  hermesSecrets = builtins.filter (s: builtins.elem "hermes-agent" s.consumers) userSecrets.secrets;

  # Resolve SOPS file paths per sopsSource.
  sopsFileForEntry =
    entry:
    if entry.sopsSource == "system" then
      ../secrets/system.yml
    else
      ../secrets/users + "/${config.home.username}.yml";

  # Parse SOPS file keys for eval-time assertion.
  # Group hermes secrets by sopsSource and check each SOPS file independently.
  hermesSystemSecrets = builtins.filter (s: s.sopsSource == "system") hermesSecrets;
  hermesUserSecrets = builtins.filter (s: s.sopsSource == "user") hermesSecrets;

  systemSopsFile = ../secrets/system.yml;
  userSopsFile = ../secrets/users + "/${config.home.username}.yml";

  hermesSystemSopsKeys =
    if hermesSystemSecrets != [ ] && builtins.pathExists systemSopsFile then
      parseSopsKeys systemSopsFile
    else
      [ ];
  hermesUserSopsKeys =
    if hermesUserSecrets != [ ] && builtins.pathExists userSopsFile then
      parseSopsKeys userSopsFile
    else
      [ ];

  missingSystemKeys = missingSopsKeys hermesSystemSopsKeys hermesSystemSecrets;
  missingUserKeys = missingSopsKeys hermesUserSopsKeys hermesUserSecrets;
  missingKeys = missingSystemKeys ++ missingUserKeys;

  # Resolve SOPS secret paths for hermes-consumed keys.
  # Each secret's sopsSource determines which SOPS file to read from.
  mkSecretPath = entry: config.sops.secrets.${entry.name}.path;

  hermesSecretPaths = map mkSecretPath hermesSecrets;
in
{

  imports = [ upstreamModule ];

  # Assert declared hermes secret key names exist in the SOPS file.
  assertions = [
    {
      assertion = missingKeys == [ ];
      message =
        "hermes-agent: keys missing from SOPS file: " + builtins.concatStringsSep ", " missingKeys;
    }
  ];

  # Declare SOPS secrets for all hermes-consumed keys.
  sops.secrets = builtins.listToAttrs (
    map (entry: {
      name = entry.name;
      value = {
        sopsFile = sopsFileForEntry entry;
        mode = "0400";
      };
    }) hermesSecrets
  );

  # ── Nucleus-level configuration ──────────────────────────────────────

  programs.hermes-agent.enable = lib.mkDefault true;

  services.hermes-agent = {
    enable = lib.mkDefault true;
    gateway.enable = if hostName == "MacBook" then lib.mkDefault true else lib.mkDefault false;
    # Wire SOPS-decrypted API key files into the service environment.
    environmentFiles = lib.mkIf (hermesSecretPaths != [ ]) hermesSecretPaths;

    # WHY: upstream's default package is `full`, which includes the `voice`
    # group (faster-whisper -> ctranslate2/onnxruntime/torch/transformers).
    # Those build from source for 30-80 min each on aarch64-darwin with no
    # binary cache, and upstream's overlay is a pure alias to its own package
    # so nucleus cannot substitute wheels for them. Restating the group list
    # without `voice` keeps every other integration while dropping the
    # expensive ML closure. Mirrors upstream's own `full` definition, including
    # `matrix` on Linux only (oqs/liboqs has no aarch64-darwin wheels).
    extraDependencyGroups = [
      "anthropic"
      "azure-identity"
      "bedrock"
      "daytona"
      "dingtalk"
      "edge-tts"
      "exa"
      "fal"
      "feishu"
      "firecrawl"
      "hindsight"
      "honcho"
      "messaging"
      "modal"
      "parallel-web"
      "tts-premium"
      "vercel"
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [ "matrix" ];
  };
}
