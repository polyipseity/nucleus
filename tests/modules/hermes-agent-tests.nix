# tests/modules/hermes-agent-tests.nix — hermes-agent provisioning validation.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  flakeText = builtins.readFile ../../src/flake.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  wrapperText = builtins.readFile ../../src/modules/hermes-agent.nix;

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
        && lib.hasInfix "entryBetween" wrapperText
        && lib.hasInfix ''[ "sops-nix" ]'' wrapperText
        && lib.hasInfix ''[ "hermesAgentSetup" ]'' wrapperText
        && lib.hasInfix "hermesSecretPaths != [ ]" wrapperText
      )
      "wrapper module must place a sops-secret barrier between sops-nix and hermesAgentSetup, gated on declared secrets";

  # === HOME.NIX IMPORT ===

  test_home_imports_hermes_agent = assert' (lib.hasInfix "./hermes-agent.nix" homeText) "home.nix must import hermes-agent.nix";

  # === LOCKFILE ===

  lockfileText = builtins.readFile ../../src/lockfiles/lockfile.json;
  test_lockfile_has_hermes_agent = assert' (lib.hasInfix ''"hermes-agent"'' lockfileText) "lockfile.json must pin hermes-agent version in uv section";

  # === PACKAGE PARITY (POSIX only — Windows uses uv tool install) ===

  test_hermes_agent_overlay_provides_package = assert' (lib.hasInfix "hermes-agent.overlays.default" flakeText) "hermes-agent overlay must provide pkgs.hermes-agent for POSIX hosts";

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
    test_home_imports_hermes_agent
    test_lockfile_has_hermes_agent
    test_hermes_agent_overlay_provides_package
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} hermes-agent tests passed";
}
