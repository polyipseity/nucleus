# tests/modules/symlinks-tests.nix — Per-user symlink wiring.

let
  fixtures = import ../fixtures/fixtures.nix { };
  inherit (fixtures) fixtureUsername loadFixtureRegistry;

  inherit (import ../lib.nix) assert' containsRegex;

  homeText = builtins.readFile ../../src/modules/home.nix;
  symlinksModuleText = builtins.readFile ../../src/modules/symlinks.nix;
  activationDagText = builtins.readFile ../../src/modules/lib/activation-dag.nix;
  fixtureSymlinksText = builtins.readFile ../fixtures/user-registry/src/users/test-user/symlinks.json;
  usersMacBook = loadFixtureRegistry "MacBook";
  usersWindows = loadFixtureRegistry "Windows";
  windowsRegistryLoaderText = builtins.readFile ../../src/platforms/Windows/modules/Load-UserRegistry.ps1;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;

  test_home_imports_symlinks_module = assert' (containsRegex ''\./symlinks\.nix'' homeText) "home.nix must import the symlinks module";

  test_symlinks_module_declares_host_targets = assert' (
    containsRegex ''options\.nucleus\.symlinks'' symlinksModuleText
    && containsRegex "mkOutOfStoreSymlink" symlinksModuleText
    && containsRegex ''"MacBook"'' symlinksModuleText
    && containsRegex ''"NixOS"'' symlinksModuleText
    && containsRegex "Windows = lib\\.mkOption" symlinksModuleText
    && containsRegex ''symlinks\.json'' symlinksModuleText
  ) "symlinks module must declare host targets and managed manifest wiring";

  test_activation_dag_keeps_symlinks = assert' (
    containsRegex ''"ensure-symlink-targets"'' activationDagText
    && containsRegex ''"prepare-symlinks"'' activationDagText
    && containsRegex ''"finalize-symlinks"'' activationDagText
    && containsRegex "home\\.activation\\.ensure-symlink-targets" symlinksModuleText
    && containsRegex "home\\.activation\\.prepare-symlinks" symlinksModuleText
    && containsRegex "home\\.activation\\.finalize-symlinks" symlinksModuleText
  ) "Shared activation DAG and symlinks module must keep all symlink activation steps";

  test_fixture_user_data_mapping_in_registries = assert' (
    containsRegex ''"symlinks"'' fixtureSymlinksText
    && containsRegex ''"path": "data"'' fixtureSymlinksText
    && containsRegex ''"MacBook": "Library/Mobile Documents/com~fixture~test/data"'' fixtureSymlinksText
    && containsRegex ''"NixOS": "clouds/GoogleDrive/data"'' fixtureSymlinksText
    && containsRegex ''"Windows": "clouds\\\\GoogleDrive\\\\data"'' fixtureSymlinksText
    && (usersMacBook.${fixtureUsername}.symlinks != [ ])
    && (usersWindows.${fixtureUsername}.symlinks != [ ])
  ) "test-user must map ~/data to fixture iCloud and Google Drive targets per host";

  test_windows_apply_wires_symlinks = assert' (
    containsRegex "symlinks" windowsRegistryLoaderText
    && containsRegex "Sync-SymlinkManifest" windowsApplyText
    && containsRegex "EnableSymlinkParity" windowsApplyText
  ) "Windows apply flow must load, expose, and run symlink parity";

  allTests = [
    test_home_imports_symlinks_module
    test_symlinks_module_declares_host_targets
    test_activation_dag_keeps_symlinks
    test_fixture_user_data_mapping_in_registries
    test_windows_apply_wires_symlinks
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} symlinks tests passed";
}
