# tests/modules/hermes-agent-tests.nix — hermes-agent provisioning validation.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  flakeText = builtins.readFile ../../src/flake.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  wrapperText = builtins.readFile ../../src/modules/hermes-agent.nix;
  # nixfmt reflows the module, so call-form assertions must be insensitive to line
  # breaks and indentation.
  wrapperTextFlat = lib.concatStringsSep " " (
    builtins.filter (part: builtins.isString part && part != "") (builtins.split "[ \t\n]+" wrapperText)
  );
  # src/users/default/ is production-managed, so reading it here is allowed; only
  # real src/users/<username>/ identities are off limits for tests.
  defaultSecretsCatalog = builtins.fromJSON (
    builtins.readFile ../../src/users/default/env-secrets.json
  );

  # === FLAKE INPUT ===

  test_hermes_agent_flake_input_declared = assert' (
    lib.hasInfix "hermes-agent = {" flakeText
    && lib.hasInfix ''url = "github:NousResearch/hermes-agent'' flakeText
  ) "flake.nix must declare hermes-agent input with NousResearch/hermes-agent URL";

  test_hermes_agent_nixpkgs_follows = assert' (
    lib.hasInfix "hermes-agent" flakeText
    && lib.hasInfix ''inputs.nixpkgs.follows = "nixpkgs"'' flakeText
  ) "hermes-agent input must follow nixpkgs to avoid duplicate evaluations";

  test_hermes_agent_in_outputs_destructure = assert' (lib.hasInfix "hermes-agent," flakeText) "hermes-agent must be destructured in the outputs function parameters";

  test_hermes_agent_overlay_in_mkpkgs = assert' (lib.hasInfix "hermes-agent.overlays.default" flakeText) "hermes-agent overlay must be in mkPkgs overlays list";

  test_hermes_agent_in_extraspecialargs_macbook = assert' (lib.hasInfix "hermes-agent = hermes-agent;" flakeText) "hermes-agent must be passed through extraSpecialArgs for MacBook";

  test_hermes_agent_in_flake_inputs = assert' (lib.hasInfix "hermes-agent = hermes-agent;" flakeText) "hermes-agent must be in flakeInputsMac for GC tracking";

  # === WRAPPER MODULE ===

  test_wrapper_module_imports_upstream = assert' (lib.hasInfix "hermes-agent.homeManagerModules.default" wrapperText) "wrapper module must import upstream homeManagerModules.default";

  test_wrapper_module_excludes_voice_group = assert' (
    lib.hasInfix "extraDependencyGroups" wrapperText && lib.hasInfix ''lib.remove "voice"'' wrapperText
  ) "wrapper module must subtract the voice group from upstream's full list (ML source builds)";

  test_wrapper_module_asserts_group_read = assert' (lib.hasInfix ''lib.elem "voice" upstreamFullDependencyGroups'' wrapperText) "wrapper module must fail closed when upstream's group list cannot be read";

  test_wrapper_module_enables_programs = assert' (lib.hasInfix "programs.hermes-agent.enable" wrapperText) "wrapper module must enable programs.hermes-agent";

  test_wrapper_module_enables_services = assert' (
    lib.hasInfix "services.hermes-agent = {" wrapperText && lib.hasInfix "gateway.enable" wrapperText
  ) "wrapper module must enable services.hermes-agent with gateway option";

  test_wrapper_module_gateway_per_host = assert' (lib.hasInfix ''hostName == "MacBook"'' wrapperText) "wrapper module must branch gateway.enable by hostName";

  test_wrapper_module_waits_for_secrets =
    assert'
      (
        lib.hasInfix "wait-for-sops-secrets.sh" wrapperText
        && lib.hasInfix "hermesSecrets != [ ]" wrapperText
        && lib.hasInfix "hermesEnvTemplatePath" wrapperText
        # entryBetween takes the BEFORE list first; passing the two lists swapped
        # silently placed the barrier after the step that reads the secrets.
        && lib.hasInfix ''entryBetween [ "hermesAgentSetup" ] [ "setupLaunchAgents" "sops-nix" ]'' wrapperTextFlat
      )
      "wrapper module must place the sops-secret barrier before hermesAgentSetup and after setupLaunchAgents + sops-nix";

  test_wrapper_module_renders_dotenv_template =
    assert'
      (
        lib.hasInfix "sops.templates" wrapperTextFlat
        && lib.hasInfix "config.sops.placeholder." wrapperTextFlat
        && lib.hasInfix "entry.envVar" wrapperTextFlat
        && lib.hasInfix "environmentFiles = lib.mkIf (hermesSecrets != [ ]) [ hermesEnvTemplatePath ];" wrapperTextFlat
        # Bare values are not dotenv, so handing the raw sops paths to upstream
        # silently drops every credential: the binding must stay deleted.
        && !(lib.hasInfix "hermesSecretPaths" wrapperText)
      )
      "wrapper module must render the hermes env vars into a dotenv sops template and pass that template to environmentFiles";

  test_wrapper_module_uses_registry_for_user_secrets =
    assert'
      (
        lib.hasInfix "users-registry.nix" wrapperText
        && lib.hasInfix ".envSecrets" wrapperText
        # The hand-rolled path resolution and its pathExists fallback must be gone: the
        # registry owns domain loading and merging.
        && !(lib.hasInfix "userSecretsFile" wrapperText)
        && !(lib.hasInfix "defaultSecretsFile" wrapperText)
        && !(lib.hasInfix "secretsFile" wrapperText)
      )
      "wrapper module must read the per-user secret catalog through the user registry instead of a hardcoded path";

  test_wrapper_module_asserts_secret_domain = assert' (lib.hasInfix "userSecrets ? secrets" wrapperText) "wrapper module must fail closed when the merged env-secrets domain declares no secrets";

  test_default_catalog_declares_hermes_user_secrets =
    let
      hermesDefaults = builtins.filter (
        s: builtins.elem "hermes-agent" s.consumers
      ) defaultSecretsCatalog.secrets;
    in
    assert'
      (builtins.length hermesDefaults > 0 && builtins.all (s: s.sopsSource == "user") hermesDefaults)
      "src/users/default/env-secrets.json must declare the hermes secrets as user-sourced (system secrets live in src/modules/env/env-secrets.json)";

  # === HOME.NIX IMPORT ===

  test_home_imports_hermes_agent = assert' (lib.hasInfix "./hermes-agent.nix" homeText) "home.nix must import hermes-agent.nix";

  # === LOCKFILE ===

  lockfileText = builtins.readFile ../../src/lockfiles/lockfile.json;
  test_lockfile_has_hermes_agent = assert' (lib.hasInfix ''"hermes-agent"'' lockfileText) "lockfile.json must pin hermes-agent version in uv section";

  # === PACKAGE PARITY (POSIX only — Windows uses uv tool install) ===

  test_hermes_agent_overlay_provides_package = assert' (lib.hasInfix "hermes-agent.overlays.default" flakeText) "hermes-agent overlay must provide pkgs.hermes-agent for POSIX hosts";

  # === PLAYWRIGHT CHROMIUM ===

  test_wrapper_module_installs_playwright = assert' (
    lib.hasInfix "install-playwright-chromium" wrapperText
    && lib.hasInfix "entryAfter" wrapperText
    && lib.hasInfix "hermesAgentSetup" wrapperTextFlat
  ) "wrapper module must have activation entry for Playwright Chromium installation after hermesAgentSetup";

  # === DATA DIRECTORY ===

  dataDirectoryText = builtins.readFile ../../src/modules/lib/data-directory.nix;

  test_data_directory_imported = assert' (lib.hasInfix "./lib/data-directory.nix" homeText) "home.nix must import data-directory.nix";

  test_data_directory_activation_entry = assert' (lib.hasInfix "provision-data-directory" homeText) "home.nix must have activation entry for data-directory provisioning";

  test_data_directory_hermes_ops = assert' (
    lib.hasInfix "hermes-agent" dataDirectoryText
    && lib.hasInfix "SOUL.md" dataDirectoryText
    && lib.hasInfix "op = \"symlink\"" dataDirectoryText
  ) "data-directory.nix must define hermes-agent directory, SOUL.md file, and symlink operations";

  allTests = [
    test_hermes_agent_flake_input_declared
    test_hermes_agent_nixpkgs_follows
    test_hermes_agent_in_outputs_destructure
    test_hermes_agent_overlay_in_mkpkgs
    test_hermes_agent_in_extraspecialargs_macbook
    test_hermes_agent_in_flake_inputs
    test_wrapper_module_imports_upstream
    test_wrapper_module_excludes_voice_group
    test_wrapper_module_asserts_group_read
    test_wrapper_module_enables_programs
    test_wrapper_module_enables_services
    test_wrapper_module_gateway_per_host
    test_wrapper_module_waits_for_secrets
    test_wrapper_module_renders_dotenv_template
    test_wrapper_module_uses_registry_for_user_secrets
    test_wrapper_module_asserts_secret_domain
    test_default_catalog_declares_hermes_user_secrets
    test_home_imports_hermes_agent
    test_lockfile_has_hermes_agent
    test_hermes_agent_overlay_provides_package
    test_wrapper_module_installs_playwright
    test_data_directory_imported
    test_data_directory_activation_entry
    test_data_directory_hermes_ops
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} hermes-agent tests passed";
}
