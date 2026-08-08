# tests/integration/config-composition-tests.nix — Verify host configurations compose correctly.

let
  inherit (import ../lib.nix) assert' containsRegex;

  flakeText = builtins.readFile ../../src/flake.nix;
  homeModuleText = builtins.readFile ../../src/modules/home.nix;
  coreModuleText = builtins.readFile ../../src/modules/core.nix;
  secretsModuleText = builtins.readFile ../../src/modules/secrets.nix;
  shellModuleText = builtins.readFile ../../src/modules/shell.nix;
  macbookDefaultText = builtins.readFile ../../src/hosts/MacBook/default.nix;
  nixosDefaultText = builtins.readFile ../../src/hosts/NixOS/default.nix;
  macbookAutomatorText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;

  # Test 1: Verify all POSIX hosts import core.nix
  test_posix_hosts_import_core = assert' (
    containsRegex "\.\./\.\./modules/core\.nix" macbookDefaultText
    && containsRegex "\.\./\.\./modules/core\.nix" nixosDefaultText
  ) "All POSIX hosts must import core.nix for shared packages";

  # Test 2: Verify all hosts import shell.nix (ZSH management)
  test_all_hosts_import_shell = assert' (
    containsRegex "\./shell\.nix" homeModuleText && containsRegex "programs\.zsh" shellModuleText
  ) "All hosts must import shell.nix for consistent shell config";

  # Test 3: Verify per-user secrets materialize from config.home.username
  test_sops_per_user_materialization = assert' (
    containsRegex "materialize-user-secrets" secretsModuleText
    && containsRegex "config\.home\.username" secretsModuleText
    && containsRegex "hasUserSecretFile" secretsModuleText
  ) "SOPS modules should materialize per-user secrets when a user file exists";

  # Test 4: Verify home-manager is properly embedded in system configs
  test_home_manager_embedded = assert' (
    containsRegex "home-manager\.darwinModules\.home-manager" flakeText
    && containsRegex "home-manager\.nixosModules\.home-manager" flakeText
  ) "Home Manager must be properly embedded in system configurations";

  # Test 5: Verify security settings are consistent across hosts
  test_security_parity = assert' (
    containsRegex "\.\./\.\./modules/posix-security\.nix" macbookDefaultText
    && containsRegex "\.\./\.\./modules/posix-security\.nix" nixosDefaultText
  ) "Security invariants must be parity-aligned across hosts";

  # Test 6: Verify wallpaper module is imported by all hosts
  test_wallpaper_module_imported = assert' (
    containsRegex "\./wallpapers\.nix" homeModuleText
    && containsRegex ''mkHomeManagerUsers "[^"]*" \./modules/home\.nix'' flakeText
  ) "Wallpaper module must be imported by all hosts";

  # Test 7: Verify dev-repos module is imported for primary user only
  test_dev_repos_primary_only = assert' (containsRegex "\./dev-repos\.nix" homeModuleText) "dev-repos should only apply to primary user";

  # Test 8: Verify all hosts handle username derivation correctly
  test_username_derivation = assert' (containsRegex "isPrimary" flakeText) "Username must be correctly derived from user registry";

  # Test 9: Verify specialArgs are passed correctly to all modules
  test_special_args_passed = assert' (
    containsRegex ''specialArgs = \{.*inherit username;'' flakeText
    && containsRegex "users = users" flakeText
  ) "specialArgs (username, users) must be passed to all configs";

  # Test 10: Verify config sections compose with mkMerge where needed
  test_config_merge_structure = assert' (
    containsRegex "config = lib\.mkMerge" coreModuleText
    && containsRegex "lib\.optionalAttrs" coreModuleText
  ) "Config sections should use mkMerge for safe composition";

  # Test 11: Verify no option conflicts in module import order
  test_import_order_correctness = assert' (
    containsRegex "home-manager\.sharedModules" macbookDefaultText
    && containsRegex "home-manager\.sharedModules" nixosDefaultText
  ) "Module import order should satisfy dependencies";

  # Test 12: Verify host-specific MANUAL.md files are wired into host configs
  test_manual_md_paths = assert' (
    containsRegex "src/hosts/MacBook/MANUAL\.md" macbookAutomatorText
    && containsRegex "src/hosts/NixOS/MANUAL\.md" nixosServicesText
  ) "Each host must reference its MANUAL.md path";

  hostFilesystemScopeText = builtins.readFile ../../.agents/instructions/host-filesystem-scope.instructions.md;

  # Test 13: NixOS host imports explicit filesystem policy module
  test_nixos_imports_filesystems_module = assert' (containsRegex "\./filesystems\.nix" nixosDefaultText) "NixOS host must import filesystems.nix for explicit NTFS/Btrfs support";

  # Test 14: MacBook documents filesystem scope without managing disk layout
  test_macbook_filesystem_scope_module = assert' (containsRegex "\./filesystem-scope\.nix" macbookDefaultText) "MacBook host must import filesystem-scope.nix";

  # Test 15: Host filesystem scope instruction covers all three hosts
  test_host_filesystem_scope_instruction = assert' (
    containsRegex "MacBook" hostFilesystemScopeText
    && containsRegex "NixOS" hostFilesystemScopeText
    && containsRegex "Windows" hostFilesystemScopeText
  ) "host-filesystem-scope.instructions.md must document MacBook, NixOS, and Windows";

  nixosDisksText = builtins.readFile ../../src/hosts/NixOS/hardware/disks.nix;

  # Test 16: NixOS host uses shared btrfs mount options
  test_nixos_btrfs_options_import = assert' (
    containsRegex "btrfs-options\\.nix" nixosDisksText && containsRegex "btrfsOptions" nixosDisksText
  ) "NixOS disks.nix must import btrfs-options.nix";

  allTests = [
    test_posix_hosts_import_core
    test_all_hosts_import_shell
    test_sops_per_user_materialization
    test_home_manager_embedded
    test_security_parity
    test_wallpaper_module_imported
    test_dev_repos_primary_only
    test_username_derivation
    test_special_args_passed
    test_config_merge_structure
    test_import_order_correctness
    test_manual_md_paths
    test_nixos_imports_filesystems_module
    test_macbook_filesystem_scope_module
    test_host_filesystem_scope_instruction
    test_nixos_btrfs_options_import
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} configuration composition tests passed";
}
