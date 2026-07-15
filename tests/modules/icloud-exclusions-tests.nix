# tests/modules/icloud-exclusions-tests.nix — macOS iCloud exclusion hook wiring.
#
# Verifies users.json exclusion names and shell/macos module wiring.

let
  lib = import <nixpkgs/lib>;
  macosModuleText = builtins.readFile ../../src/modules/macos.nix;
  shellModuleText = builtins.readFile ../../src/modules/shell.nix;
  users = builtins.fromJSON (builtins.readFile ../../src/modules/users.json);

  inherit (import ../lib.nix) assert';

  user = users.polyipseity;
  excludedDirNames = user.iCloudExclusions.excludedDirNames;
  managedRoots = user.iCloudExclusions.managedRoots;

  test_exclusion_list_exists = assert' (
    (builtins.length excludedDirNames) > 0
  ) "users.json must define a non-empty iCloudExclusions.excludedDirNames list";

  test_managed_roots_centralized = assert' (
    managedRoots == [
      "Library/Mobile Documents/com~apple~CloudDocs"
      "Library/Mobile Documents/iCloud~md~obsidian"
    ]
  ) "users.json must define the exact centralized iCloudExclusions.managedRoots list for polyipseity";

  test_managed_roots_are_mobile_documents_only = assert' (builtins.all
    (root: lib.hasPrefix "Library/Mobile Documents/" root)
    managedRoots
  ) "users.json iCloudExclusions.managedRoots must stay inside Library/Mobile Documents only";

  test_plain_mobile_documents_root_is_rejected =
    assert'
      (
        (lib.hasInfix "root != \"Library/Mobile Documents\"" macosModuleText)
        && (lib.hasInfix "root != \"Library/Mobile Documents\"" shellModuleText)
      )
      "macos and shell iCloud sanitizers must explicitly reject the plain Library/Mobile Documents root";

  test_default_root_is_only_clouddocs =
    assert'
      (
        (lib.hasInfix ''[ "Library/Mobile Documents/com~apple~CloudDocs" ]'' macosModuleText)
        && (lib.hasInfix ''[ "Library/Mobile Documents/com~apple~CloudDocs" ]'' shellModuleText)
      )
      "default iCloud exclusion roots must fall back to only Library/Mobile Documents/com~apple~CloudDocs";

  test_required_python_dirs_present = assert' (
    (builtins.elem ".venv" excludedDirNames)
    && (builtins.elem ".pytest_cache" excludedDirNames)
    && (builtins.elem ".hypothesis" excludedDirNames)
    && (builtins.elem ".ruff_cache" excludedDirNames)
    && (builtins.elem "__pycache__" excludedDirNames)
  ) "users.json iCloudExclusions list must include expected Python cache/venv directories";

  test_required_node_dirs_present = assert' (
    (builtins.elem "node_modules" excludedDirNames) && (builtins.elem ".pnpm-store" excludedDirNames)
  ) "users.json iCloudExclusions list must include expected Node cache/dependency directories";

  test_shell_uses_chpwd_hook = assert' (
    (lib.hasInfix "add-zsh-hook chpwd __nucleus_check_icloud_exclusions_on_pwd_change" shellModuleText)
    && (lib.hasInfix "__nucleus_mark_icloud_exclusions_under" shellModuleText)
  ) "shell.nix must run iCloud exclusion checks on directory entry via chpwd";

  test_shell_keeps_mkdir_hook = assert' (
    (lib.hasInfix "mkdir()" shellModuleText)
    && (lib.hasInfix "__nucleus_check_icloud_exclusion \"$arg\"" shellModuleText)
  ) "shell.nix must keep mkdir-triggered iCloud exclusion checks";

  test_macos_activation_recursive_pass = assert' (
    (lib.hasInfix "configureICloudExclusions" macosModuleText)
    && (lib.hasInfix "com.apple.fileprovider.ignore#P" macosModuleText)
    && (lib.hasInfix "sanitizeICloudManagedRoots" macosModuleText)
  ) "macos.nix must retain activation-time recursive iCloud exclusion pass";

  test_shell_restricts_roots_to_mobile_documents = assert' (
    (lib.hasInfix "Library/Mobile Documents/com~apple~CloudDocs" shellModuleText)
    && (lib.hasInfix "lib.hasPrefix \"Library/Mobile Documents/\"" shellModuleText)
  ) "shell.nix must sanitize managed roots to Library/Mobile Documents subpaths only";

  test_shell_adds_precmd_hook = assert' (lib.hasInfix "add-zsh-hook precmd __nucleus_check_icloud_exclusions_immediate" shellModuleText) "shell.nix must register a precmd hook for iCloud exclusions";

  test_shell_uses_depth1_scan_in_precmd = assert' (lib.hasInfix "maxdepth 1" shellModuleText) "shell.nix precmd hook must use -maxdepth 1 to avoid recursion on every prompt";

  test_shell_does_not_recurse_in_precmd = assert' (
    !lib.hasInfix "__nucleus_mark_icloud_exclusions_under" (
      builtins.head (builtins.split "__nucleus_check_icloud_exclusions_immediate" shellModuleText).rest
    )
  ) "shell.nix precmd hook must not call the recursive __nucleus_mark_icloud_exclusions_under";

  test_launchagent_hourly_interval = assert' (lib.hasInfix "StartInterval = 3600" macosModuleText) "macos.nix must use StartInterval 3600 (hourly) for the iCloud exclusion LaunchAgent";

  allTests = [
    test_exclusion_list_exists
    test_managed_roots_centralized
    test_managed_roots_are_mobile_documents_only
    test_plain_mobile_documents_root_is_rejected
    test_default_root_is_only_clouddocs
    test_required_python_dirs_present
    test_required_node_dirs_present
    test_shell_uses_chpwd_hook
    test_shell_keeps_mkdir_hook
    test_macos_activation_recursive_pass
    test_shell_restricts_roots_to_mobile_documents
    test_shell_adds_precmd_hook
    test_shell_uses_depth1_scan_in_precmd
    test_shell_does_not_recurse_in_precmd
    test_launchagent_hourly_interval
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} iCloud exclusion tests passed";
}
