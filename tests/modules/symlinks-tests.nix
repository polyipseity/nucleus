# tests/modules/symlinks-tests.nix — Per-user symlink wiring.

let
  inherit (import ../lib.nix) assert' containsRegex;

  homeText = builtins.readFile ../../src/modules/home.nix;
  symlinksModuleText = builtins.readFile ../../src/modules/symlinks.nix;
  activationDagText = builtins.readFile ../../src/modules/lib/activation-dag.nix;
  polyipseitySymlinksText = builtins.readFile ../../src/users/polyipseity/symlinks.json;
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
    && containsRegex "home\.activation\.ensure-symlink-targets" symlinksModuleText
    && containsRegex "home\.activation\.prepare-symlinks" symlinksModuleText
    && containsRegex "home\.activation\.finalize-symlinks" symlinksModuleText
  ) "Shared activation DAG and symlinks module must keep all symlink activation steps";

  test_polyipseity_data_mapping_in_registries = assert' (
    containsRegex ''"symlinks"'' polyipseitySymlinksText
    && containsRegex ''"path": "data"'' polyipseitySymlinksText
    && containsRegex ''"MacBook": "Library/Mobile Documents/com~apple~CloudDocs/data"'' polyipseitySymlinksText
    && containsRegex ''"NixOS": "clouds/GoogleDrive/data"'' polyipseitySymlinksText
    && containsRegex ''"Windows": "clouds\\\\GoogleDrive\\\\data"'' polyipseitySymlinksText
    && (usersMacOS.polyipseity.symlinks != [ ])
    && (usersWindows.polyipseity.symlinks != [ ])
  ) "polyipseity must map ~/data to native iCloud on macOS and Google Drive elsewhere";

  test_windows_apply_wires_symlinks = assert' (
    containsRegex "symlinks" windowsRegistryLoaderText
    && containsRegex "Sync-SymlinkManifest" windowsApplyText
    && containsRegex "EnableSymlinkParity" windowsApplyText
  ) "Windows apply flow must load, expose, and run symlink parity";

  allTests = [
    test_home_imports_symlinks_module
    test_symlinks_module_declares_host_targets
    test_activation_dag_keeps_symlinks
    test_polyipseity_data_mapping_in_registries
    test_windows_apply_wires_symlinks
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} symlinks tests passed";
}
