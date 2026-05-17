# tests/nix/icloud-exclusions-tests.nix — Validate macOS iCloud exclusion hook wiring.
#
# Verifies that iCloud exclusion names are declared in users.json and that
# shell/macos modules wire both directory-entry and mkdir triggers.
#
# Run with: nix-instantiate --eval tests/nix/icloud-exclusions-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  macosModuleText = builtins.readFile ../../src/modules/macos.nix;
  shellModuleText = builtins.readFile ../../src/modules/shell.nix;
  users = builtins.fromJSON (builtins.readFile ../../src/modules/users.json);

  assert' = cond: msg: if !cond then builtins.throw msg else null;

  user = users.polyipseity;
  excludedDirNames = user.iCloudExclusions.excludedDirNames;

  test_exclusion_list_exists = assert' (
    (builtins.length excludedDirNames) > 0
  ) "users.json must define a non-empty iCloudExclusions.excludedDirNames list";

  test_required_python_dirs_present = assert' (
    (builtins.elem ".venv" excludedDirNames)
    && (builtins.elem ".pytest_cache" excludedDirNames)
    && (builtins.elem ".hypothesis" excludedDirNames)
    && (builtins.elem ".ruff_cache" excludedDirNames)
    && (builtins.elem "__pycache__" excludedDirNames)
  ) "users.json iCloudExclusions list must include expected Python cache/venv directories";

  test_required_node_dirs_present = assert' (
    (builtins.elem "node_modules" excludedDirNames)
    && (builtins.elem ".pnpm-store" excludedDirNames)
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
  ) "macos.nix must retain activation-time recursive iCloud exclusion pass";

  allTests = [
    test_exclusion_list_exists
    test_required_python_dirs_present
    test_required_node_dirs_present
    test_shell_uses_chpwd_hook
    test_shell_keeps_mkdir_hook
    test_macos_activation_recursive_pass
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} iCloud exclusion tests passed";
}
