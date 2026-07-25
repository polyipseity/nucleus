# tests/modules/custom-provision-symlinks-tests.nix — Custom provision symlink wiring.

let
  inherit (import ../lib.nix) assert' containsRegex;

  homeText = builtins.readFile ../../src/modules/home.nix;
  customModuleText = builtins.readFile ../../src/modules/custom-provision-symlinks.nix;
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  posixUsersText = builtins.readFile ../../src/modules/users.json;
  windowsUsersText = builtins.readFile ../../src/hosts/Windows/users.json;
  windowsRegistryLoaderText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;

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
    containsRegex ''"ensure-custom-provision-symlink-targets"'' macosText
    && containsRegex ''"prepare-custom-provision-symlinks"'' macosText
    && containsRegex ''"finalize-custom-provision-symlinks"'' macosText
    && containsRegex ''"ensure-custom-provision-symlink-targets"'' linuxText
    && containsRegex ''"prepare-custom-provision-symlinks"'' linuxText
    && containsRegex ''"finalize-custom-provision-symlinks"'' linuxText
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
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} custom provision symlink tests passed";
}
