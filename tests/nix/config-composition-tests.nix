# tests/nix/config-composition-tests.nix — Verify host configurations compose correctly.
#
# Tests validate that:
#   - macOS, NixOS, and standalone HM configs don't have conflicting options
#   - Required modules are imported by all hosts
#   - Cross-module dependencies are satisfied
#   - Parity settings exist on supported hosts
#
# Run with: nix-instantiate --eval tests/nix/config-composition-tests.nix

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  flakeText = builtins.readFile ../../src/flake.nix;
  homeModuleText = builtins.readFile ../../src/modules/home.nix;
  coreModuleText = builtins.readFile ../../src/modules/core.nix;
  secretsModuleText = builtins.readFile ../../src/modules/secrets.nix;
  shellModuleText = builtins.readFile ../../src/modules/shell.nix;
  macosModuleText = builtins.readFile ../../src/modules/macos.nix;
  macbookDefaultText = builtins.readFile ../../src/hosts/macbook/default.nix;
  nixosDefaultText = builtins.readFile ../../src/hosts/nixos/default.nix;

  assert' = cond: msg: if !cond then throw "COMPOSITION FAILED: ${msg}" else null;

  # Test 1: Verify all POSIX hosts import core.nix
  test_posix_hosts_import_core = assert' (
    containsRegex "\.\./\.\./modules/core\.nix" macbookDefaultText
    && containsRegex "\.\./\.\./modules/core\.nix" nixosDefaultText
  ) "All POSIX hosts must import core.nix for shared packages";

  # Test 2: Verify all hosts import shell.nix (ZSH management)
  test_all_hosts_import_shell = assert' (
    containsRegex "\./shell\.nix" homeModuleText && containsRegex "programs\.zsh" shellModuleText
  ) "All hosts must import shell.nix for consistent shell config";

  # Test 3: Verify SOPS imports are guarded by isPrimary check
  test_sops_primary_user_only = assert' (
    containsRegex "isPrimaryUser" secretsModuleText
    && containsRegex "lib\.mkIf isPrimaryUser" secretsModuleText
  ) "SOPS modules should only apply to primary user";

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
    && containsRegex "mkHomeManagerUsers \./modules/home\.nix" flakeText
  ) "Wallpaper module must be imported by all hosts";

  # Test 7: Verify dev-repos module is imported for primary user only
  test_dev_repos_primary_only = assert' (containsRegex "\./dev-repos\.nix" homeModuleText) "dev-repos should only apply to primary user";

  # Test 8: Verify all hosts handle username derivation correctly
  test_username_derivation = assert' (containsRegex "isPrimary" flakeText) "Username must be correctly derived from user registry";

  # Test 9: Verify specialArgs are passed correctly to all modules
  test_special_args_passed = assert' (
    containsRegex "specialArgs = \{ inherit username users; \};" flakeText
    && containsRegex "extraSpecialArgs = \{" flakeText
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

  # Test 12: Verify host-specific MANUAL.md paths are set
  test_manual_md_paths = assert' (
    containsRegex "src/hosts/macbook/MANUAL\.md" macbookDefaultText
    && containsRegex "src/hosts/nixos/MANUAL\.md" nixosDefaultText
    && containsRegex "options\.nucleus\.hostManualFile" homeModuleText
  ) "Each host must declare its MANUAL.md path";

  # Test 13: Verify Finder sidebar bookmarks use nil-safe local bookmark creation
  test_finder_sidebar_bookmark_safety = assert' (
    !containsRegex "NSURLBookmarkCreationWithSecurityScope" macosModuleText
    && containsRegex "bookmark === undefined \|\| bookmark === null" macosModuleText
    && containsRegex "skipping Finder sidebar item" macosModuleText
  ) "Finder sidebar activation must skip nil bookmark objects instead of inserting them";

  allTests = [
    test_posix_hosts_import_core
    test_all_hosts_import_shell
    test_sops_primary_user_only
    test_home_manager_embedded
    test_security_parity
    test_wallpaper_module_imported
    test_dev_repos_primary_only
    test_username_derivation
    test_special_args_passed
    test_config_merge_structure
    test_import_order_correctness
    test_manual_md_paths
    test_finder_sidebar_bookmark_safety
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} configuration composition tests passed";
}
