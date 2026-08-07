# tests/modules/custom-provision-symlinks-tests.nix — Custom provision symlink wiring.

let
  inherit (import ../lib.nix) assert' containsRegex;

  homeText = builtins.readFile ../../src/modules/home.nix;
  customModuleText = builtins.readFile ../../src/modules/custom-provision-symlinks.nix;
  activationDagText = builtins.readFile ../../src/modules/lib/activation-dag.nix;
  customSymlinksText = builtins.readFile ../../src/users/polyipseity/custom-provision-symlinks.json;
  usersMacOS = import ../../src/modules/lib/users-registry.nix {
    lib = import <nixpkgs/lib>;
    repoRoot = ../..;
    hostName = "MacBook";
  };
  usersWindows = import ../../src/modules/lib/users-registry.nix {
    lib = import <nixpkgs/lib>;
    repoRoot = ../..;
    hostName = "Windows";
  };
  windowsRegistryLoaderText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;

  test_home_imports_custom_module = assert' (containsRegex ''\./custom-provision-symlinks\.nix'' homeText) "home.nix must import the custom provision symlink module";

  test_custom_module_declares_host_targets = assert' (
    containsRegex ''options\.nucleus\.customProvisionSymlinks'' customModuleText
    && containsRegex "mkOutOfStoreSymlink" customModuleText
    && containsRegex ''"MacBook"'' customModuleText
    && containsRegex ''"NixOS"'' customModuleText
    && containsRegex "Windows = lib\\.mkOption" customModuleText
    && containsRegex ''custom-provision-symlinks\.json'' customModuleText
  ) "custom provision symlink module must declare host targets and managed manifest wiring";

  test_activation_dag_keeps_custom_symlinks =
    assert'
      (
        containsRegex ''"ensure-custom-provision-symlink-targets"'' activationDagText
        && containsRegex ''"prepare-custom-provision-symlinks"'' activationDagText
        && containsRegex ''"finalize-custom-provision-symlinks"'' activationDagText
        && containsRegex "home\.activation\.ensure-custom-provision-symlink-targets" customModuleText
        && containsRegex "home\.activation\.prepare-custom-provision-symlinks" customModuleText
        && containsRegex "home\.activation\.finalize-custom-provision-symlinks" customModuleText
      )
      "Shared activation DAG and custom-provision-symlinks module must keep all custom symlink activation steps";

  test_polyipseity_data_mapping_in_registries = assert' (
    containsRegex ''"customProvisionSymlinks"'' customSymlinksText
    && containsRegex ''"path": "data"'' customSymlinksText
    && containsRegex ''"MacBook": "Library/Mobile Documents/com~apple~CloudDocs/data"'' customSymlinksText
    && containsRegex ''"NixOS": "clouds/GoogleDrive/data"'' customSymlinksText
    && containsRegex ''"Windows": "clouds\\\\GoogleDrive\\\\data"'' customSymlinksText
    && (usersMacOS.polyipseity.customProvisionSymlinks != [ ])
    && (usersWindows.polyipseity.customProvisionSymlinks != [ ])
  ) "polyipseity must map ~/data to native iCloud on macOS and Google Drive elsewhere";

  test_windows_apply_wires_custom_symlinks = assert' (
    containsRegex "customProvisionSymlinks" windowsRegistryLoaderText
    && containsRegex "Sync-CustomProvisionSymlink" windowsApplyText
    && containsRegex "EnableCustomProvisionSymlinkParity" windowsApplyText
  ) "Windows apply flow must load, expose, and run custom provision symlink parity";

  allTests = [
    test_home_imports_custom_module
    test_custom_module_declares_host_targets
    test_activation_dag_keeps_custom_symlinks
    test_polyipseity_data_mapping_in_registries
    test_windows_apply_wires_custom_symlinks
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} custom provision symlink tests passed";
}
