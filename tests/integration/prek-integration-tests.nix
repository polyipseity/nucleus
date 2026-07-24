# tests/integration/prek-integration-tests.nix — Verify prek lifecycle integration.
#
# Guards the cross-host prek contract: binary parity, apply-time installation,
# and shell-driven hook installation across POSIX and Windows.
#
{
  lib ? import <nixpkgs/lib>,
}:
let
  # Read the live files so this test catches wiring drift in the real repo.
  applyScriptText = builtins.readFile ../../src/scripts/apply.sh;
  installPrekHooksText = builtins.readFile ../../src/scripts/install-prek-hooks.sh;
  coreModuleText = builtins.readFile ../../src/modules/core.nix;
  flakeText = builtins.readFile ../../src/flake.nix;
  posixPwshText = builtins.readFile ../../src/modules/pwsh.nix;
  posixShellText = builtins.readFile ../../src/modules/shell.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  agentEnvVarNames = (import ../../src/modules/agent-env-vars.nix).agentEnvVarNames;
  windowsInstallModuleText = builtins.readFile ../../src/hosts/Windows/modules/setup/Install-PrekHook.ps1;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;
  windowsSystemPackagesDscText = builtins.readFile ../../src/hosts/Windows/system/packages.dsc.yml;
  windowsUserDscText = builtins.readFile ../../src/hosts/Windows/user/shell.dsc.yml;

  inherit (import ../lib.nix) assert';

  test_posix_binary_baseline = assert' (lib.hasInfix "pkgs.prek" coreModuleText) "POSIX shared package baseline must include pkgs.prek";

  test_windows_binary_baseline = assert' (lib.hasInfix "id: j178.Prek" windowsSystemPackagesDscText) "Windows system/packages.dsc.yml must include the j178.Prek package";

  test_apply_runtime_bundles_prek = assert' (
    (lib.hasInfix "runtimeInputs = [" flakeText) && (lib.hasInfix "pkgs.prek" flakeText)
  ) "mkApplyApp runtimeInputs must bundle pkgs.prek for first-run apply hook installation";

  test_posix_apply_installs_hooks = assert' (
    (lib.hasInfix "install-prek-hooks.sh" applyScriptText)
    && (lib.hasInfix "prek install" installPrekHooksText)
  ) "POSIX apply flow must install prek hooks for the live repository";

  test_zsh_hook_installs_hooks = assert' (
    (lib.hasInfix "_prek_hook_install_if_needed()" posixShellText)
    && (lib.hasInfix "add-zsh-hook chpwd _prek_hook_install_if_needed" posixShellText)
  ) "zsh initContent must auto-install prek hooks on directory change";

  test_posix_pwsh_hook_installs_hooks = assert' (
    (lib.hasInfix "Invoke-PrekHookInstallIfNeeded" posixPwshText)
    && (lib.hasInfix "function global:prompt" posixPwshText)
  ) "POSIX PowerShell profile must auto-install prek hooks when pwsh enters a repo";

  test_windows_apply_installs_hooks = assert' (
    (lib.hasInfix "Install-PrekHook.ps1" windowsApplyText)
    && (lib.hasInfix "Install-PrekHook -PrekExecutablePath $prekExe -RepositoryRoot $repoRoot" windowsApplyText)
  ) "Windows apply flow must install prek hooks for the live repository";

  test_windows_install_module_exists = assert' (
    (lib.hasInfix "function Install-PrekHook" windowsInstallModuleText)
    && (lib.hasInfix "prek install" windowsInstallModuleText)
  ) "Windows Install-PrekHook module must exist and run prek install";

  test_windows_shell_hook_installs_hooks = assert' (
    (lib.hasInfix "Invoke-PrekHookInstallIfNeeded" windowsShellProfileText)
    && (lib.hasInfix "function global:prompt" windowsShellProfileText)
  ) "Windows shell profile must auto-install prek hooks when pwsh enters a repo";

  test_posix_prek_uses_git_rev_parse = assert' (lib.hasInfix "git rev-parse --git-dir" installPrekHooksText) "POSIX install-prek-hooks.sh must use 'git rev-parse --git-dir' to handle .git as file (submodules, worktrees)";

  test_windows_prek_uses_git_rev_parse = assert' (lib.hasInfix "git rev-parse --git-dir" posixPwshText) "Windows pwsh Test-PrekHooksInstalled must use 'git rev-parse --git-dir' to handle .git as file (submodules, worktrees)";

  test_posix_prek_handles_relative_git_dir = assert' (lib.hasInfix "_ephi_git_dir=" installPrekHooksText) "POSIX install-prek-hooks.sh must store git-dir output and construct hook path dynamically";

  test_windows_prek_handles_relative_git_dir = assert' (lib.hasInfix "IsPathRooted" posixPwshText) "Windows pwsh must handle relative paths from git rev-parse --git-dir using IsPathRooted check";

  test_zsh_agent_session_detection = assert' (
    (lib.hasInfix "__nucleus_is_agent_session" posixShellText)
    && (lib.hasInfix "! __nucleus_is_agent_session" posixShellText)
  ) "zsh initContent must define __nucleus_is_agent_session and guard pay-respects behind it";

  test_windows_agent_session_detection = assert' (
    (lib.hasInfix "Test-NucleusAgentSession" windowsShellProfileText)
    && (lib.hasInfix "-not (Test-NucleusAgentSession)" windowsShellProfileText)
  ) "Windows shell profile must define Test-NucleusAgentSession and guard pay-respects behind it";

  test_posix_pwsh_agent_session_detection = assert' (
    (lib.hasInfix "Test-NucleusAgentSession" posixPwshText)
    && (lib.hasInfix "-not (Test-NucleusAgentSession)" posixPwshText)
  ) "POSIX pwsh profile must define Test-NucleusAgentSession and guard pay-respects behind it";

  test_windows_agent_env_vars_complete = assert' (lib.all (
    var: lib.hasInfix "env:${var}" windowsShellProfileText
  ) agentEnvVarNames) "Windows shell profile must check all env vars listed in agent-env-vars.nix";

  test_zsh_agent_session_suppression = assert' (
    (lib.hasInfix "if __nucleus_is_agent_session; then" posixShellText)
    && (lib.hasInfix "unsetopt ZLE" posixShellText)
    && (lib.hasInfix "PS1=\"%% \"" posixShellText)
  ) "zsh initContent must suppress ZLE and flatten prompt in AI agent sessions";

  test_posix_pwsh_agent_session_suppression = assert' (
    (lib.hasInfix "Remove-Module PSReadLine" posixPwshText)
    && (lib.hasInfix "function prompt { \"PS> \" }" posixPwshText)
    && (lib.hasInfix "if (Test-NucleusAgentSession)" posixPwshText)
  ) "POSIX pwsh profile must suppress PSReadLine and flatten prompt in AI agent sessions";

  test_windows_pwsh_agent_session_suppression = assert' (
    (lib.hasInfix "Remove-Module PSReadLine -ErrorAction SilentlyContinue" windowsShellProfileText)
    && (lib.hasInfix "function prompt { \"PS> \" }" windowsShellProfileText)
  ) "Windows pwsh profile must suppress PSReadLine and flatten prompt in AI agent sessions";

  test_windows_cmd_autorun_agent_detection = assert' (
    (lib.hasInfix "cmdAutoRun" windowsUserDscText)
    && (lib.hasInfix "AutoRun" windowsUserDscText)
    && lib.all (var: lib.hasInfix "if not defined ${var}" windowsUserDscText) agentEnvVarNames
  ) "Windows user/shell.dsc.yml must define cmdAutoRun RegistryValue that checks all agent env vars";

  test_zsh_agent_env_vars_complete = assert' (lib.all (
    var: lib.hasInfix "[[ -n \"\${${var}:-}\" ]] && return 0" posixShellText
  ) agentEnvVarNames) "zsh initContent must check all env vars listed in agent-env-vars.nix";

  test_posix_pwsh_agent_env_vars_complete = assert' (lib.all (
    var: lib.hasInfix "env:${var}" posixPwshText
  ) agentEnvVarNames) "POSIX pwsh profile must check all env vars listed in agent-env-vars.nix";
in
builtins.seq
  (builtins.deepSeq {
    inherit
      test_posix_binary_baseline
      test_windows_binary_baseline
      test_apply_runtime_bundles_prek
      test_posix_apply_installs_hooks
      test_zsh_hook_installs_hooks
      test_posix_pwsh_hook_installs_hooks
      test_windows_apply_installs_hooks
      test_windows_install_module_exists
      test_windows_shell_hook_installs_hooks
      test_posix_prek_uses_git_rev_parse
      test_windows_prek_uses_git_rev_parse
      test_posix_prek_handles_relative_git_dir
      test_windows_prek_handles_relative_git_dir
      test_zsh_agent_session_detection
      test_windows_agent_session_detection
      test_posix_pwsh_agent_session_detection
      test_windows_agent_env_vars_complete
      test_zsh_agent_session_suppression
      test_posix_pwsh_agent_session_suppression
      test_windows_pwsh_agent_session_suppression
      test_windows_cmd_autorun_agent_detection
      test_zsh_agent_env_vars_complete
      test_posix_pwsh_agent_env_vars_complete
      ;
  })
  {
    success = true;
    testCount = 23;
    message = "All 23 prek integration tests passed";
  }
