# tests/nix/prek-integration-tests.nix — Verify prek lifecycle integration.
#
# Guards the cross-host prek contract: binary parity, apply-time installation,
# and shell-driven hook installation across POSIX and Windows.
#
# Run with: nix-instantiate --eval tests/nix/prek-integration-tests.nix

{ lib ? import <nixpkgs/lib> }:
let
  # Read the live files so this test catches wiring drift in the real repo.
  applyScriptText = builtins.readFile ../../src/scripts/apply.sh;
  coreModuleText = builtins.readFile ../../src/modules/core.nix;
  flakeText = builtins.readFile ../../src/flake.nix;
  posixPwshText = builtins.readFile ../../src/modules/pwsh.nix;
  posixShellText = builtins.readFile ../../src/modules/shell.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/windows/apply.ps1;
  windowsInstallModuleText = builtins.readFile ../../src/hosts/windows/modules/Install-PrekHook.ps1;
  windowsShellProfileText = builtins.readFile ../../src/hosts/windows/modules/Sync-ShellProfile.ps1;
  windowsSystemDscText = builtins.readFile ../../src/hosts/windows/system.dsc.yml;

  # Simple assertion helper with descriptive errors.
  assert' = cond: msg: if !cond then builtins.throw msg else null;

  test_posix_binary_baseline =
    assert'
      (lib.hasInfix "pkgs.prek" coreModuleText)
      "POSIX shared package baseline must include pkgs.prek";

  test_windows_binary_baseline =
    assert'
      (lib.hasInfix "id: j178.Prek" windowsSystemDscText)
      "Windows system.dsc.yml must include the j178.Prek package";

  test_apply_runtime_bundles_prek =
    assert'
      ((lib.hasInfix "runtimeInputs = [" flakeText) &&
       (lib.hasInfix "pkgs.prek" flakeText))
      "mkApplyApp runtimeInputs must bundle pkgs.prek for first-run apply hook installation";

  test_posix_apply_installs_hooks =
    assert'
      ((lib.hasInfix "ensure_prek_hooks_installed()" applyScriptText) &&
       (lib.hasInfix "prek install" applyScriptText))
      "POSIX apply flow must install prek hooks for the live repository";

  test_zsh_hook_installs_hooks =
    assert'
      ((lib.hasInfix "_prek_hook_install_if_needed()" posixShellText) &&
       (lib.hasInfix "add-zsh-hook chpwd _prek_hook_install_if_needed" posixShellText))
      "zsh initContent must auto-install prek hooks on directory change";

  test_posix_pwsh_hook_installs_hooks =
    assert'
      ((lib.hasInfix "Invoke-PrekHookInstallIfNeeded" posixPwshText) &&
       (lib.hasInfix "function global:prompt" posixPwshText))
      "POSIX PowerShell profile must auto-install prek hooks when pwsh enters a repo";

  test_windows_apply_installs_hooks =
    assert'
      ((lib.hasInfix "Install-PrekHook.ps1" windowsApplyText) &&
       (lib.hasInfix "Install-PrekHook -PrekExecutablePath $prekExe -RepositoryRoot $repoRoot" windowsApplyText))
      "Windows apply flow must install prek hooks for the live repository";

  test_windows_install_module_exists =
    assert'
      ((lib.hasInfix "function Install-PrekHook" windowsInstallModuleText) &&
       (lib.hasInfix "prek install" windowsInstallModuleText))
      "Windows Install-PrekHook module must exist and run prek install";

  test_windows_shell_hook_installs_hooks =
    assert'
      ((lib.hasInfix "Invoke-PrekHookInstallIfNeeded" windowsShellProfileText) &&
       (lib.hasInfix "function global:prompt" windowsShellProfileText))
      "Windows shell profile must auto-install prek hooks when pwsh enters a repo";

  allTests = [
    test_posix_binary_baseline
    test_windows_binary_baseline
    test_apply_runtime_bundles_prek
    test_posix_apply_installs_hooks
    test_zsh_hook_installs_hooks
    test_posix_pwsh_hook_installs_hooks
    test_windows_apply_installs_hooks
    test_windows_install_module_exists
    test_windows_shell_hook_installs_hooks
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} prek integration tests passed";
  testNames = [
    "1: POSIX shared package baseline includes pkgs.prek"
    "2: Windows DSC baseline includes j178.Prek"
    "3: Apply runtime bundles prek"
    "4: POSIX apply installs hooks"
    "5: zsh hook auto-installs hooks"
    "6: POSIX pwsh hook auto-installs hooks"
    "7: Windows apply installs hooks"
    "8: Windows Install-PrekHook module exists"
    "9: Windows pwsh hook auto-installs hooks"
  ];
}
