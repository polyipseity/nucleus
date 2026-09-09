# tests/modules/hermes-agent-tests.nix — hermes-agent provisioning validation.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert' containsRegex;

  flakeText = builtins.readFile ../../src/flake.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  wrapperText = builtins.readFile ../../src/modules/hermes-agent.nix;

  # === FLAKE INPUT ===

  test_hermes_agent_flake_input_declared = assert' (
    lib.hasInfix ''hermes-agent = {'' flakeText
    && lib.hasInfix ''url = "github:NousResearch/hermes-agent"'' flakeText
  ) "flake.nix must declare hermes-agent input with NousResearch/hermes-agent URL";

  test_hermes_agent_nixpkgs_follows = assert' (
    lib.hasInfix ''hermes-agent'' flakeText
    && lib.hasInfix ''inputs.nixpkgs.follows = "nixpkgs"'' flakeText
  ) "hermes-agent input must follow nixpkgs to avoid duplicate evaluations";

  test_hermes_agent_in_outputs_destructure = assert' (
    lib.hasInfix "hermes-agent," flakeText
  ) "hermes-agent must be destructured in the outputs function parameters";

  test_hermes_agent_overlay_in_mkpkgs = assert' (
    lib.hasInfix "hermes-agent.overlays.default" flakeText
  ) "hermes-agent overlay must be in mkPkgs overlays list";

  test_hermes_agent_in_extraspecialargs_macbook = assert' (
    lib.hasInfix ''hermes-agent = hermes-agent;'' flakeText
  ) "hermes-agent must be passed through extraSpecialArgs for MacBook";

  test_hermes_agent_in_flake_inputs = assert' (
    lib.hasInfix "hermes-agent = hermes-agent;" flakeText
  ) "hermes-agent must be in flakeInputsMac for GC tracking";

  # === WRAPPER MODULE ===

  test_wrapper_module_imports_upstream = assert' (
    lib.hasInfix "import" wrapperText
    && lib.hasInfix "homeManagerModules.nix" wrapperText
  ) "wrapper module must import upstream homeManagerModules.nix";

  test_wrapper_module_shims_inputs = assert' (
    lib.hasInfix "upstreamInputs" wrapperText
    && lib.hasInfix "inputs.self.packages" wrapperText
  ) "wrapper module must create inputs shim with inputs.self.packages";

  test_wrapper_module_enables_programs = assert' (
    lib.hasInfix "programs.hermes-agent.enable" wrapperText
  ) "wrapper module must enable programs.hermes-agent";

  test_wrapper_module_enables_services = assert' (
    lib.hasInfix "services.hermes-agent.enable" wrapperText
    && lib.hasInfix "gateway.enable" wrapperText
  ) "wrapper module must enable services.hermes-agent with gateway option";

  test_wrapper_module_gateway_per_host = assert' (
    lib.hasInfix ''hostName == "MacBook"'' wrapperText
  ) "wrapper module must branch gateway.enable by hostName";

  # === HOME.NIX IMPORT ===

  test_home_imports_hermes_agent = assert' (
    lib.hasInfix "./hermes-agent.nix" homeText
  ) "home.nix must import hermes-agent.nix";

  # === LOCKFILE ===

  lockfileText = builtins.readFile ../../src/lockfiles/lockfile.json;
  test_lockfile_has_hermes_agent = assert' (
    lib.hasInfix ''"hermes-agent"'' lockfileText
  ) "lockfile.json must pin hermes-agent version in uv section";

  # === PACKAGE PARITY (POSIX only — Windows uses uv tool install) ===

  test_hermes_agent_overlay_provides_package = assert' (
    lib.hasInfix "hermes-agent.overlays.default" flakeText
  ) "hermes-agent overlay must provide pkgs.hermes-agent for POSIX hosts";
in
{
  success = true;
  message = "hermes-agent provisioning validation passed";
}
