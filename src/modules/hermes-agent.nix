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

  # Shared activation-script bundle (same derivation every activation block uses).
  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

  # The flake-parts output already binds `inputs` internally —
  # homeManagerModules.default is a standard HM module {config, lib, ...}:
  upstreamModule = hermes-agent.homeManagerModules.default;

  # Upstream's default package (`full`) is `minimal.override` with a
  # dependency-group list written inline in its `nix/packages.nix`, and nothing
  # exports that list. Read it back by evaluating that file with a stubbed
  # flake-parts context and capturing the argument upstream passes to `override`.
  #
  # The host's real `stdenv` is passed through deliberately: upstream's own
  # `lib.optionals pkgs.stdenv.isLinux [ "matrix" ]` then resolves for the
  # target platform, so the extracted list already carries or omits `matrix`.
  # `isLinux` is shadowed to keep upstream's deprecated alias from emitting a
  # nixpkgs deprecation warning.
  upstreamFullDependencyGroups =
    ((import "${hermes-agent}/nix/packages.nix" { inherit (hermes-agent) inputs; }).perSystem {
      pkgs = {
        callPackage = _file: _args: { override = newArgs: newArgs.extraDependencyGroups or [ ]; };
        stdenv = pkgs.stdenv // {
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
        };
      };
      inherit lib;
      inputs = { };
      inputs' = {
        npm-lockfile-fix = {
          packages.default = null;
        };
      };
    }).packages.default;

  # Resolve the per-user secret catalog through the user registry, so a
  # src/users/<username>/env-secrets.json override is merged over
  # src/users/default/env-secrets.json by the same contract as every other domain
  # (user wins; an array field is replaced wholesale, never unioned). System
  # secrets are a separate catalog (src/modules/env/env-secrets.json).
  allUsers = import ./lib/users-registry.nix {
    lib = pkgs.lib;
    repoRoot = ../..;
    inherit hostName;
  };
  userRecord = allUsers.${config.home.username} or { };
  userSecrets = userRecord.envSecrets or { };

  # Filter secrets by consumer: only keys where consumers contains "hermes-agent".
  # `or [ ]` keeps this total so the assertion below reports a missing domain with
  # its own message instead of a raw attribute error.
  hermesSecrets = builtins.filter (s: builtins.elem "hermes-agent" s.consumers) (
    userSecrets.secrets or [ ]
  );

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

  # Upstream builds ~/.hermes/.env by concatenating every `environmentFiles`
  # entry verbatim, so each entry must be dotenv-formatted (`KEY=value`). The
  # env-secrets catalog stores each secret as a bare value, so the raw sops paths
  # cannot be passed through: python-dotenv reads a bare line as a key with an
  # unknown value and drops it, leaving the gateway unauthenticated without any
  # error. A sops template renders the catalog's `envVar` names onto the
  # decrypted values, which is the shape upstream consumes.
  hermesEnvTemplate = "hermes-env";
  hermesEnvTemplatePath = config.sops.templates.${hermesEnvTemplate}.path;
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
    {
      assertion = lib.elem "voice" upstreamFullDependencyGroups;
      message = "hermes-agent: could not read upstream's `full` dependency-group list — nix/packages.nix layout changed";
    }
    {
      # The registry tolerates an absent domain file (it yields { }); without this
      # assertion a moved/renamed default catalog would silently wire no secrets.
      assertion = userSecrets ? secrets;
      message = "hermes-agent: no merged env-secrets domain for '${config.home.username}' — src/users/default/env-secrets.json is missing or has no 'secrets' key";
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

  # WHY: upstream reads `environmentFiles` during `hermesAgentSetup`, and on macOS
  # sops-nix materializes those files from an asynchronous LaunchAgent — ordering
  # the consumer merely `entryAfter [ "sops-nix" ]` does not guarantee they exist
  # when the read happens, which produced one warning per unreadable path. The
  # barrier polls for the rendered template, which sops-install-secrets writes
  # after the secrets and exposes only once it swaps the generation symlink.
  # Gated on a non-empty secret list so hosts without hermes secrets declare no
  # entry.
  home.activation.wait-for-hermes-secrets = lib.mkIf (hermesSecrets != [ ]) (
    lib.hm.dag.entryBetween [ "sops-nix" ] [ "hermesAgentSetup" ] ''
      "${activationBundle}/src/scripts/secrets/wait-for-sops-secrets.sh" \
        ${lib.escapeShellArg hermesEnvTemplatePath}
    ''
  );

  # `config.sops.placeholder.<name>` is defined by sops-nix only while
  # `sops.templates` is non-empty, so the template is also what makes the
  # placeholder map available. Skipped wholesale (not an empty template) when no
  # hermes secret is declared — an empty template is a hard error in
  # sops-install-secrets.
  sops.templates = lib.optionalAttrs (hermesSecrets != [ ]) {
    ${hermesEnvTemplate} = {
      mode = "0400";
      content = lib.concatMapStringsSep "\n" (
        entry: "${entry.envVar}=${config.sops.placeholder.${entry.name}}"
      ) hermesSecrets;
    };
  };

  # ── Nucleus-level configuration ──────────────────────────────────────

  programs.hermes-agent.enable = lib.mkDefault true;

  services.hermes-agent = {
    enable = lib.mkDefault true;
    gateway.enable = if hostName == "MacBook" then lib.mkDefault true else lib.mkDefault false;
    # Wire the rendered dotenv file into the service environment. An empty secret
    # value is legitimate (the key is simply not configured yet) and renders as
    # `KEY=`, which hermes reads as unconfigured; the barrier above waits for the
    # file to appear and never for non-emptiness.
    environmentFiles = lib.mkIf (hermesSecrets != [ ]) [ hermesEnvTemplatePath ];

    # WHY: upstream's default package is `full`, which includes the `voice`
    # group (faster-whisper -> ctranslate2/onnxruntime/torch/transformers).
    # Those build from source for 30-80 min each on aarch64-darwin with no
    # binary cache, and upstream's overlay is a pure alias to its own package
    # so nucleus cannot substitute wheels for them. Subtracting the group from
    # upstream's own list keeps every other integration while dropping the
    # expensive ML closure, and follows upstream adding or removing an
    # integration instead of silently desynchronising this file.
    # `matrix` needs no special-casing here: it is already present or absent
    # depending on the platform upstream evaluated for.
    extraDependencyGroups = lib.remove "voice" upstreamFullDependencyGroups;
  };
}
