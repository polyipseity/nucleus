# tests/src/custom-provision-symlinks-tests.nix — Validate custom provision symlink wiring.
#
# Ensures the shared per-user custom symlink mechanism is imported, platform-aware,
# and configured to expose ~/data using iCloud on macOS and Google Drive elsewhere.
#
# Run with: nix-instantiate --eval tests/src/custom-provision-symlinks-tests.nix

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  homeText = builtins.readFile ../../src/modules/home.nix;
  customModuleText = builtins.readFile ../../src/modules/custom-provision-symlinks.nix;
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  posixUsersText = builtins.readFile ../../src/modules/users.json;
  windowsUsersText = builtins.readFile ../../src/hosts/Windows/users.json;
  windowsRegistryLoaderText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;

  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  test_home_imports_custom_module = assert' (containsRegex ''\.\/custom-provision-symlinks\.nix'' homeText) "home.nix must import the custom provision symlink module";

  test_custom_module_declares_platform_targets = assert' (
    containsRegex ''options\.nucleus\.customProvisionSymlinks'' customModuleText
    && containsRegex "mkOutOfStoreSymlink" customModuleText
    && containsRegex ''"macos"'' customModuleText
    && containsRegex ''"linux"'' customModuleText
    && containsRegex ''"windows"'' customModuleText
    && containsRegex ''custom-provision-symlinks\.json'' customModuleText
  ) "custom provision symlink module must declare platform targets and managed manifest wiring";

  test_manual_instruction_terminal_order_keeps_custom_symlinks = assert' (
    containsRegex ''"ensureCustomProvisionSymlinkTargets"'' macosText
    && containsRegex ''"prepareCustomProvisionSymlinks"'' macosText
    && containsRegex ''"finalizeCustomProvisionSymlinks"'' macosText
    && containsRegex ''"ensureCustomProvisionSymlinkTargets"'' linuxText
    && containsRegex ''"prepareCustomProvisionSymlinks"'' linuxText
    && containsRegex ''"finalizeCustomProvisionSymlinks"'' linuxText
  ) "macOS and Linux terminal activation lists must include all custom symlink activation steps";

  test_polyipseity_data_mapping_in_registries = assert' (
    containsRegex ''"customProvisionSymlinks"'' posixUsersText
    && containsRegex ''"path": "data"'' posixUsersText
    && containsRegex ''"macos": "Library/Mobile Documents/com~apple~CloudDocs/data"'' posixUsersText
    && containsRegex ''"linux": "clouds/GoogleDrive/data"'' posixUsersText
    && containsRegex ''"windows": "clouds\\\\GoogleDrive\\\\data"'' posixUsersText
    && containsRegex ''"customProvisionSymlinks"'' windowsUsersText
    && containsRegex ''"path": "data"'' windowsUsersText
    && containsRegex ''"windows": "clouds\\\\GoogleDrive\\\\data"'' windowsUsersText
  ) "polyipseity must map ~/data to native iCloud on macOS and Google Drive elsewhere";

  test_windows_apply_wires_custom_symlinks = assert' (
    containsRegex "customProvisionSymlinks" windowsRegistryLoaderText
    && containsRegex "Sync-CustomProvisionSymlink" windowsApplyText
    && containsRegex "EnableCustomProvisionSymlinkParity" windowsApplyText
  ) "Windows apply flow must load, expose, and run custom provision symlink parity";

  allTests = [
    test_home_imports_custom_module
    test_custom_module_declares_platform_targets
    test_manual_instruction_terminal_order_keeps_custom_symlinks
    test_polyipseity_data_mapping_in_registries
    test_windows_apply_wires_custom_symlinks
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} custom provision symlink tests passed";
}
