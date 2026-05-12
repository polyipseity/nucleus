# tests/nix/default-dev-tooling-tests.nix — Verify managed fallback tooling policy wiring.
#
# Guards the cross-host contract for repositories that do not ship direnv/Nix
# metadata: POSIX shells must expose the dedicated fallback tool bundle and
# Windows PowerShell must expose the managed default shell environment.
#
# Run with: nix-instantiate --eval tests/nix/default-dev-tooling-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  applyScriptText = builtins.readFile ../../src/hosts/windows/apply.ps1;
  buildToolsPolicyText = builtins.readFile ../../.agents/instructions/build-tools-policy.instructions.md;
  ciWorkflowText = builtins.readFile ../../.github/workflows/ci.yml;
  posixPwshText = builtins.readFile ../../src/modules/pwsh.nix;
  posixShellText = builtins.readFile ../../src/modules/shell.nix;
  windowsShellProfileText = builtins.readFile ../../src/hosts/windows/modules/Sync-ShellProfile.ps1;

  # Simple assertion helper with descriptive errors.
  assert' = cond: msg: if !cond then throw msg else null;

  test_posix_shell_exports_fallback_bundle = assert' (
    (lib.hasInfix "default-dev-tools" posixShellText)
    && (lib.hasInfix "NUCLEUS_DEFAULT_DEV_BIN" posixShellText)
    && (lib.hasInfix "export NUCLEUS_DEFAULT_DEV_BIN=" posixShellText)
    && (lib.hasInfix "__nucleus_run_managed_dev_tool" posixShellText)
  ) "shell.nix must publish the fallback tool bundle and helper for unmanaged repositories";

  test_posix_pwsh_uses_fallback_bundle = assert' (
    (lib.hasInfix "default-dev-tools" posixPwshText)
    && (lib.hasInfix "NUCLEUS_DEFAULT_DEV_BIN" posixPwshText)
    && (lib.hasInfix "Invoke-NucleusManagedDevTool" posixPwshText)
  ) "pwsh.nix must publish and consume the fallback tool bundle for unmanaged repositories";

  test_windows_shell_uses_default_env = assert' (
    (lib.hasInfix "NUCLEUS_DEFAULT_DEV_ENV" windowsShellProfileText)
    && (lib.hasInfix "Invoke-NucleusManagedDevTool" windowsShellProfileText)
  ) "Sync-ShellProfile.ps1 must expose the managed default shell environment on Windows";

  test_windows_apply_wires_shell_profile_sync = assert' (
    (lib.hasInfix "Sync-ShellProfile.ps1" applyScriptText)
    && (lib.hasInfix "Sync-ShellProfile -Enabled:$EnableShellParity" applyScriptText)
  ) "Windows apply.ps1 must load and execute Sync-ShellProfile so fallback shell policy is enforced";

  test_policy_docs_capture_fallback = assert' (
    (lib.hasInfix "NUCLEUS_DEFAULT_DEV_BIN" buildToolsPolicyText)
    && (lib.hasInfix "NUCLEUS_DEFAULT_DEV_ENV" buildToolsPolicyText)
  ) "Build tools policy instructions must document the managed fallback environment";

  test_ci_runs_this_suite = assert' (lib.hasInfix "tests/nix/default-dev-tooling-tests.nix" ciWorkflowText) "CI must execute the managed fallback tooling tests";

  allTests = [
    test_posix_shell_exports_fallback_bundle
    test_posix_pwsh_uses_fallback_bundle
    test_windows_shell_uses_default_env
    test_windows_apply_wires_shell_profile_sync
    test_policy_docs_capture_fallback
    test_ci_runs_this_suite
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} managed fallback tooling tests passed";
  testNames = [
    "1: POSIX zsh exports fallback tool bundle"
    "2: POSIX pwsh uses fallback tool bundle"
    "3: Windows shell profile exposes default environment"
    "4: Windows apply wires shell profile sync"
    "5: Build tools policy documents fallback environment"
    "6: CI executes fallback tooling tests"
  ];
}
