# src/modules/hermes-agent.nix — Nucleus wrapper for upstream hermes-agent Home Manager module.
#
# Wraps upstream's `programs.hermes-agent` and `services.hermes-agent`. API keys
# go in the per-user env-secrets.json with consumers: ["hermes-agent"] plus the
# matching SOPS entries.
{
  config,
  lib,
  pkgs,
  hostName,
  hermes-agent,
  repoRoot,
  ...
}:
let
  sopsUtils = import ./lib/sops-utils.nix;
  inherit (sopsUtils) parseSopsKeys;

  # Secret selection and coverage auditing live in a pure library so both rules
  # are fixture-testable without a NixOS evaluation.
  hermesSecretUtils = import ./lib/hermes-secrets.nix;

  # Resolves the bridge plugin through the shared per-user overlay contract.
  overlay = (import ./lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    effectiveUsername = config.home.username;
    inherit repoRoot hostName;
  };

  # Shared activation-script bundle (same derivation every activation block uses).
  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

  # homeManagerModules.default is a standard HM module {config, lib, ...}.
  upstreamModule = hermes-agent.homeManagerModules.default;

  # Upstream's `full` package is `minimal.override` with the dependency-group list
  # written inline in `nix/packages.nix` and exported nowhere, so read it back by
  # evaluating that file with a stubbed flake-parts context. The host's real
  # stdenv is passed through so upstream's own `isLinux` test resolves for the
  # target platform and the extracted list already carries `matrix`; isLinux is
  # shadowed to silence the deprecated alias.
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

  # Resolved through the user registry, so a per-user env-secrets.json overrides
  # the default domain by the shared contract. System secrets are separate.
  allUsers = import ./lib/users-registry.nix {
    lib = pkgs.lib;
    repoRoot = ../..;
    inherit hostName;
  };
  userRecord = allUsers.${config.home.username} or { };
  userSecrets = userRecord.envSecrets or { };

  # WHY `or [ ]`: keeps this total so the assertion reports a missing domain with
  # its own message instead of a raw attribute error.
  hermesSecretGroups = hermesSecretUtils.selectHermesSecrets (userSecrets.secrets or [ ]);
  hermesSecrets = hermesSecretGroups.all;

  # Resolve SOPS file paths per sopsSource.
  sopsFileForEntry =
    entry:
    if entry.sopsSource == "system" then
      ../secrets/system.yml
    else
      ../secrets/users + "/${config.home.username}.yml";

  # A group is checked against its own file, and only when it has entries, since
  # an absent file is otherwise indistinguishable from an empty one.
  hermesSystemSecrets = hermesSecretGroups.system;
  hermesUserSecrets = hermesSecretGroups.user;

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

  missingKeys =
    (hermesSecretUtils.auditHermesSecrets {
      groups = hermesSecretGroups;
      systemKeys = hermesSystemSopsKeys;
      userKeys = hermesUserSopsKeys;
    }).all;

  # WHY a template: upstream concatenates `environmentFiles` verbatim, so each
  # entry must be dotenv (`KEY=value`). The catalog stores bare values, and
  # python-dotenv drops a bare line, leaving the gateway unauthenticated with no
  # error. The template renders envVar names onto the decrypted values.
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
      # The registry tolerates an absent domain file, so without this assertion a
      # moved or renamed default catalog would silently wire no secrets.
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

  # WHY: macOS sops-nix materializes secrets from an async LaunchAgent, so
  # entryAfter does not guarantee the file exists at read time. entryBetween
  # lists BEFORE first: this runs before hermesAgentSetup and after
  # setupLaunchAgents (which copies the plist in before bootstrap) and sops-nix.
  # setupLaunchAgents is absent on Linux, where sops-nix runs synchronously.
  home.activation.wait-for-hermes-secrets = lib.mkIf (hermesSecrets != [ ]) (
    lib.hm.dag.entryBetween [ "hermesAgentSetup" ] [ "setupLaunchAgents" "sops-nix" ] ''
      "${activationBundle}/src/scripts/secrets/wait-for-sops-secrets.sh" \
        ${lib.escapeShellArg hermesEnvTemplatePath}
    ''
  );

  # sops-nix defines `config.sops.placeholder` only while templates are
  # non-empty, so the template is also what makes the map exist. Skipped
  # wholesale when no secret is declared, since an empty template is fatal.
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
    # An empty secret value is legitimate and renders as `KEY=`, which hermes
    # reads as unconfigured.
    environmentFiles = lib.mkIf (hermesSecrets != [ ]) [ hermesEnvTemplatePath ];

    # Hermes gates user plugins on `plugins.enabled`, and `settings` is written to
    # config.yaml, independent of whether the gateway runs here.
    settings.plugins.enabled = [ "harness-bridge" ];

    # WHY drop `voice`: its ML closure builds from source for 30-80 min each on
    # aarch64-darwin with no binary cache, and upstream's overlay is a pure alias
    # so nucleus cannot substitute wheels. Removing it from upstream's own list
    # tracks upstream's integrations instead of freezing a copy here.
    extraDependencyGroups = lib.remove "voice" upstreamFullDependencyGroups;
  };

  # Writable symlink into the live repo tree, so the plugin edits without a rebuild.
  home.activation.seed-hermes-harness-bridge-plugin = lib.mkIf config.programs.hermes-agent.enable (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "$HOME/.hermes/plugins/harness-bridge" \
        "${overlay.toRepoRelPath (overlay.selectFile "hermes" "plugins/harness-bridge")}" \
        "${hostName}"
    ''
  );

  # WHY: the upstream plist hardcodes the log paths and offers no override, so
  # symlinks from the nucleus log directory make `nucleus-svc logs` find them.
  home.activation.symlink-hermes-logs = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      _hermes_log_dir="${config.home.homeDirectory}/Library/Application Support/nucleus/logs/hermes-agent"
      mkdir -p "$_hermes_log_dir"
      chown "${config.home.username}" "$_hermes_log_dir"
      for _f in "${config.home.homeDirectory}/Library/Logs/hermes-agent.log" \
                "${config.home.homeDirectory}/Library/Logs/hermes-agent.err.log"; do
        if [ -f "$_f" ] && [ ! -L "$_hermes_log_dir/$(basename "$_f")" ]; then
          ln -s "$_f" "$_hermes_log_dir/$(basename "$_f")"
        fi
      done
    ''
  );

  # Playwright browsers come from pkgs.playwright-driver.browsers in core.nix.
  # Windows has no store, so Sync-HermesConfig uses the bun.playwright pin.
}
