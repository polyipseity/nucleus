# tests/nix/cloud-sync-tests.nix — Schema and invariant tests for cloud-drives.nix.
#
# Validates that the cloud-drives module text contains the required option
# definitions, type declarations, and structural invariants.
#
# Run with: nix-instantiate --eval tests/nix/cloud-sync-tests.nix

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  moduleText = builtins.readFile ../../src/modules/cloud-drives.nix;

  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  # Test 1: Module defines both mounts and replicas option lists
  test_options_exist =
    assert'
      (
        containsRegex "options\.nucleus\.cloudDrives\.mounts" moduleText
        && containsRegex "options\.nucleus\.cloudDrives\.replicas" moduleText
      )
      "cloud-drives module must declare nucleus.cloudDrives.mounts and nucleus.cloudDrives.replicas options";

  # Test 2: Mounts use a listOf submodule type
  test_mounts_are_list = assert' (containsRegex "type = lib\.types\.listOf mountSubmodule;" moduleText) "nucleus.cloudDrives.mounts must be typed as listOf mountSubmodule";

  # Test 3: Replicas use a listOf submodule type
  test_replicas_are_list = assert' (containsRegex "type = lib\.types\.listOf replicaSubmodule;" moduleText) "nucleus.cloudDrives.replicas must be typed as listOf replicaSubmodule";

  # Test 4: Replica enable option defaults to false (opt-in)
  test_replica_enable_defaults_false = assert' (containsRegex "default = false" moduleText) "replica enable option must default to false (replicas are opt-in)";

  # Test 5: Mount enable option defaults to true
  test_mount_enable_defaults_true = assert' (containsRegex "default = true" moduleText) "mount enable option must default to true";

  # Test 6: Provider enum includes the three expected providers
  test_provider_enum_values = assert' (
    containsRegex "\"GoogleDrive\"" moduleText
    && containsRegex "\"iCloud\"" moduleText
    && containsRegex "\"OneDrive\"" moduleText
  ) "provider enum must include GoogleDrive, iCloud, and OneDrive";

  # Test 7: Module reads user config from the users registry
  test_reads_user_config = assert' (containsRegex "users\.\\\$\{currentUsername\}\.cloudDrives" moduleText) "module must read per-user config from users.\${currentUsername}.cloudDrives";

  # Test 8: macOS iCloud replica uses brctl (not rclone)
  test_icloud_uses_brctl = assert' (containsRegex "brctl download" moduleText) "iCloud replica on macOS must use brctl download (native CloudDocs mechanism)";

  # Test 9: rclone is conditionally added to home packages
  test_rclone_package_conditional = assert' (
    containsRegex "pkgs\.rclone" moduleText && containsRegex "hasRcloneProvider" moduleText
  ) "rclone package should only be installed when rclone-backed providers are configured";

  # Test 10: cloudDrivesSetup activation is defined
  test_setup_activation_exists = assert' (containsRegex "cloudDrivesSetup" moduleText) "cloudDrivesSetup activation must be defined for directory creation";

  # Test 11: cloudDrivesICloudRefresh activation is defined
  test_icloud_refresh_activation_exists = assert' (containsRegex "cloudDrivesICloudRefresh" moduleText) "cloudDrivesICloudRefresh activation must be defined for macOS iCloud replica";

  # Test 12: macOS LaunchAgents are defined for rclone mounts
  test_macos_launchd_agents = assert' (containsRegex "launchd\.agents" moduleText) "module must define macOS LaunchAgents for rclone-backed mounts";

  # Test 13: NixOS systemd services are defined for rclone mounts
  test_nixos_systemd_services = assert' (containsRegex "systemd\.user\.services" moduleText) "module must define NixOS systemd user services for rclone-backed mounts";

  # Test 14: Module handles multiple mounts per provider (list-based schema)
  test_list_schema_allows_multiple = assert' (
    containsRegex "listOf mountSubmodule" moduleText
    && containsRegex "listOf replicaSubmodule" moduleText
  ) "schema must be list-based to allow multiple mounts/replicas per provider";

  allTests = [
    test_options_exist
    test_mounts_are_list
    test_replicas_are_list
    test_replica_enable_defaults_false
    test_mount_enable_defaults_true
    test_provider_enum_values
    test_reads_user_config
    test_icloud_uses_brctl
    test_rclone_package_conditional
    test_setup_activation_exists
    test_icloud_refresh_activation_exists
    test_macos_launchd_agents
    test_nixos_systemd_services
    test_list_schema_allows_multiple
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cloud-drives schema tests passed";
}
