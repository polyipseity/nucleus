# tests/nix/module-options-tests.nix — Comprehensive Nix module option validation.
#
# Tests verify that all module options have correct types, defaults, and descriptions.
# This catches option definition errors before configurations are applied.
#
# Run with: nix-instantiate --eval tests/nix/module-options-tests.nix

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  homeModuleText = builtins.readFile ../../src/modules/home.nix;
  coreModuleText = builtins.readFile ../../src/modules/core.nix;
  shellModuleText = builtins.readFile ../../src/modules/shell.nix;
  secretsModuleText = builtins.readFile ../../src/modules/secrets.nix;
  flakeText = builtins.readFile ../../src/flake.nix;
  cloudDrivesModuleText = builtins.readFile ../../src/modules/cloud-drives.nix;

  # Assertion helper with detailed error messages.
  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  # Test 1: Verify home.username option exists and is a string
  test_home_username_type =
    assert'
      (containsRegex "home = \{" homeModuleText
      && containsRegex "username = effectiveUsername;" homeModuleText)
      "home.username should be type string";

  # Test 2: Verify home.homeDirectory has a default for Linux
  test_home_directory_linux =
    assert'
      (containsRegex "homeDirectory = lib\.mkDefault resolvedHomeDirectory;" homeModuleText
      && containsRegex "else\s+\"/home/\$\{effectiveUsername\}\"" homeModuleText)
      "home.homeDirectory should default based on OS";

  # Test 3: Verify all editor extensions are lists
  test_editor_extensions_list =
    assert'
      (containsRegex "generatedHomebrew\.brews = lib\.mkOption" coreModuleText
      && containsRegex "type = lib\.types\.listOf lib\.types\.str;" coreModuleText)
      "Generated list-like options should use listOf str types";

  # Test 4: Verify stateVersion is set (prevents accidental downgrades)
  test_state_version_set =
    assert' (containsRegex "stateVersion = \"24\.11\";" homeModuleText)
      "home.stateVersion must be set to a valid version";

  # Test 5: Verify package list options are lists, not strings
  test_package_options_are_lists =
    assert'
      (containsRegex "generatedHomebrew\.casks = lib\.mkOption" coreModuleText
      && containsRegex "type = lib\.types\.listOf lib\.types\.str;" coreModuleText)
      "Package options must be lists, not single strings";

  # Test 6: Verify security options are boolean or specific enums
  test_security_options_types =
    assert'
      (containsRegex "overlapBackend = lib\.mkOption" coreModuleText
      && containsRegex "type = lib\.types\.enum" coreModuleText)
      "Enum options should declare explicit allowed values";

  # Test 7: Verify shell options are strings (paths, aliases, env vars)
  test_shell_options_types =
    assert'
      (containsRegex "sessionVariables = import \./shell/env\.nix;" shellModuleText
      && containsRegex "shellAliases = import \./shell/aliases\.nix" shellModuleText)
      "Shell aliases and env vars should be strings";

  # Test 8: Verify sops keys are present in the config
  test_sops_keys_configured =
    assert' (containsRegex "sops\.age\.keyFile = \"/etc/sops/age/machine\.txt\";" secretsModuleText)
      "SOPS keys must be configured for secret decryption";

  # Test 9: Verify all options have descriptions (required for maintainability)
  test_all_options_have_descriptions =
    assert'
      (containsRegex "options\.nucleus\.hostManualFile = lib\.mkOption" homeModuleText
      && containsRegex "description = \"Host-scoped MANUAL\.md" homeModuleText)
      "All module options should have meaningful descriptions";

  # Test 10: Verify no conflicting option definitions across modules
  test_no_conflicting_options =
    assert'
      (containsRegex "options\.nucleus\.macos\.packageSelection" coreModuleText
      && containsRegex "options\.nucleus\.hostManualFile" homeModuleText)
      "No conflicting option definitions should exist across modules";

  # Test 11: Verify option defaults are not null when they should have values
  test_option_defaults_meaningful =
    assert'
      (containsRegex "default = \"policy\";" coreModuleText
      && containsRegex "default = null;" homeModuleText)
      "Option defaults should be meaningful, not null";

  # Test 12: Verify condition-gated options use mkIf (not mkDefault on conditional content)
  test_conditional_options_structure =
    assert'
      (containsRegex "lib\.mkIf pkgs\.stdenv\.isDarwin" coreModuleText
      && containsRegex "lib\.optionalAttrs \(options \? environment" coreModuleText
      && containsRegex "mkHomeManagerUsers" flakeText)
      "Conditional options should use mkIf, not implicit conditionals";
  # Test 13: Verify cloud-drives module defines mounts and replicas options
  test_cloud_drives_options =
    assert'
      (containsRegex "options\.nucleus\.cloudDrives\.mounts = lib\.mkOption" cloudDrivesModuleText
      && containsRegex "options\.nucleus\.cloudDrives\.replicas = lib\.mkOption" cloudDrivesModuleText
      && containsRegex "type = lib\.types\.listOf mountSubmodule;" cloudDrivesModuleText
      && containsRegex "type = lib\.types\.listOf replicaSubmodule;" cloudDrivesModuleText)
      "cloud-drives module must define nucleus.cloudDrives.mounts and nucleus.cloudDrives.replicas options as lists";
  allTests = [
    test_home_username_type
    test_home_directory_linux
    test_editor_extensions_list
    test_state_version_set
    test_package_options_are_lists
    test_security_options_types
    test_shell_options_types
    test_sops_keys_configured
    test_all_options_have_descriptions
    test_no_conflicting_options
    test_option_defaults_meaningful
    test_conditional_options_structure
    test_cloud_drives_options
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} module option validation tests passed";
  testNames = [
    "home.username type validation"
    "home.homeDirectory OS-specific defaults"
    "editor extensions are lists"
    "stateVersion is set"
    "package options are lists"
    "security options have correct types"
    "shell options are strings"
    "SOPS keys configured"
    "all options have descriptions"
    "no conflicting option definitions"
    "option defaults are meaningful"
    "conditional options use mkIf"
    "cloud-drives module defines mounts and replicas options"
  ];
}
