# tests/platforms/macOS/modules/icloud-exclusions-tests.nix — macOS iCloud exclusion hook wiring.
#
# Verifies src/users/ exclusion names and shell/macos module wiring.

let
  lib = import <nixpkgs/lib>;
  macosModuleText = builtins.readFile ../../../src/platforms/macOS/modules/default.nix;
  shellModuleText = builtins.readFile ../../../src/modules/shell.nix;
  # The zsh hook functions (chpwd, precmd, mkdir wrapper) live in an external
  # script embedded into shell.nix's initContent via builtins.readFile.
  icloudHooksText = builtins.readFile ../../../src/platforms/macOS/scripts/macos-install-icloud-hooks.zsh;
  usersRegistry = import ../../../src/modules/lib/users-registry.nix {
    inherit lib;
    repoRoot = ../../..;
    hostName = "MacBook";
  };

  inherit (import ../../../lib.nix) assert';

  user = usersRegistry.polyipseity;
  excludedDirNames = user.iCloudExclusions.excludedDirNames;
  managedRoots = user.iCloudExclusions.managedRoots;

  test_exclusion_list_exists = assert' (
    (builtins.length excludedDirNames) > 0
  ) "src/users/ registry must define a non-empty iCloudExclusions.excludedDirNames list";

  test_managed_roots_centralized =
    assert'
      (
        managedRoots == [
          "Library/Mobile Documents/com~apple~CloudDocs"
          "Library/Mobile Documents/iCloud~md~obsidian"
        ]
      )
      "src/users/ registry must define the exact centralized iCloudExclusions.managedRoots list for polyipseity";

  test_managed_roots_are_mobile_documents_only = assert' (builtins.all
    (root: lib.hasPrefix "Library/Mobile Documents/" root)
    managedRoots
  ) "src/users/ iCloudExclusions.managedRoots must stay inside Library/Mobile Documents only";

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
  ) "src/users/ iCloudExclusions list must include expected Python cache/venv directories";

  test_required_node_dirs_present = assert' (
    (builtins.elem "node_modules" excludedDirNames) && (builtins.elem ".pnpm-store" excludedDirNames)
  ) "src/users/ iCloudExclusions list must include expected Node cache/dependency directories";

  test_shell_uses_chpwd_hook = assert' (
    (lib.hasInfix "macos-install-icloud-hooks.zsh" shellModuleText)
    && (lib.hasInfix "add-zsh-hook chpwd __nucleus_check_icloud_exclusions_on_pwd_change" icloudHooksText)
    && (lib.hasInfix "__nucleus_mark_icloud_exclusions_under" icloudHooksText)
  ) "shell.nix must embed iCloud exclusion hooks that run on directory entry via chpwd";

  test_shell_keeps_mkdir_hook = assert' (
    (lib.hasInfix "mkdir()" icloudHooksText)
    && (lib.hasInfix "__nucleus_check_icloud_exclusion \"$arg\"" icloudHooksText)
  ) "shell.nix must keep mkdir-triggered iCloud exclusion checks";

  test_macos_activation_recursive_pass = assert' (
    (lib.hasInfix "macos-configure-icloud-exclusions" macosModuleText)
    && (lib.hasInfix "com.apple.fileprovider.ignore#P" macosModuleText)
    && (lib.hasInfix "sanitizeICloudManagedRoots" macosModuleText)
  ) "macos.nix must retain activation-time recursive iCloud exclusion pass";

  test_shell_restricts_roots_to_mobile_documents = assert' (
    (lib.hasInfix "Library/Mobile Documents/com~apple~CloudDocs" shellModuleText)
    && (lib.hasInfix "lib.hasPrefix \"Library/Mobile Documents/\"" shellModuleText)
  ) "shell.nix must sanitize managed roots to Library/Mobile Documents subpaths only";

  test_shell_adds_precmd_hook = assert' (lib.hasInfix "add-zsh-hook precmd __nucleus_check_icloud_exclusions_immediate" icloudHooksText) "shell.nix must register a precmd hook for iCloud exclusions";

  test_shell_uses_depth1_scan_in_precmd = assert' (lib.hasInfix "-maxdepth 1" icloudHooksText) "shell.nix precmd hook must use -maxdepth 1 to avoid recursion on every prompt";

  test_shell_does_not_recurse_in_precmd =
    let
      # The precmd function body is everything between its definition and its
      # add-zsh-hook registration in the embedded hooks script.
      afterDef = builtins.elemAt (builtins.split "__nucleus_check_icloud_exclusions_immediate" icloudHooksText) 2;
      immediateBody = builtins.elemAt (builtins.split "add-zsh-hook precmd" afterDef) 0;
    in
    assert' (
      !lib.hasInfix "__nucleus_mark_icloud_exclusions_under" immediateBody
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
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} iCloud exclusion tests passed";
}
