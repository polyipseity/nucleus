# tests/integration/shell-completions-tests.nix — Verify shell completion coverage for nucleus-* commands.

let
  lib = import <nixpkgs/lib>;
  zshCompDir = ../../src/modules/completions/zsh;
  zshCompFiles = builtins.readDir zshCompDir;
  shellText = builtins.readFile ../../src/modules/shell.nix;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;

  inherit (import ../lib.nix) assert';

  # All nucleus commands that should have completions.
  # Ordered to match mkNucleusApps in flake.nix.
  nucleusCommands = [
    "nucleus-apply"
    "nucleus-ai"
    "nucleus-bootstrap"
    "nucleus-bump-lockfile"
    "nucleus-check"
    "nucleus-check-packer"
    "nucleus-check-pwsh"
    "nucleus-check-sh"
    "nucleus-cloud-setup"
    "nucleus-config"
    "nucleus-gs-pdf-opt"
    "nucleus-gc"
    "nucleus-health-check"
    "nucleus-replica-reset"
    "nucleus-replica-sync"
    "nucleus-svc"
    "nucleus-service-watchdog"
    "nucleus-test"
    "nucleus-update"
    "nucleus-vm"
  ];

  # Map command name to zsh completion file name (prepends _ to the full command name)
  zshCompName = cmd: "_${cmd}";

  # --- Zsh completion files exist for every command ---
  test_zsh_completions_exist_for_all = assert' (lib.all
    (cmd: builtins.hasAttr (zshCompName cmd) zshCompFiles)
    nucleusCommands
  ) "Every nucleus command must have a zsh completion file in src/modules/completions/zsh/";

  # --- Zsh completion files contain a #compdef directive ---
  test_zsh_completions_have_compdef =
    assert'
      (lib.all (
        cmd:
        let
          compName = zshCompName cmd;
          compFile = builtins.readFile (zshCompDir + "/${compName}");
        in
        lib.hasInfix "#compdef ${cmd}" compFile || lib.hasInfix "#compdef nucleus-" compFile
      ) nucleusCommands)
      "Every zsh completion file must have a #compdef directive for its command (or the fallback _nucleus)";

  # --- Zsh completions are installed by activation hook ---
  test_zsh_completions_installed_by_shell_nix = assert' (
    lib.hasInfix "install-zsh-completions" shellText && lib.hasInfix "./completions/zsh" shellText
  ) "shell.nix installZshCompletions must copy nucleus completion files";

  # --- Windows PowerShell completions ---
  test_windows_pwsh_has_completers_for_all = assert' (lib.all
    (cmd: lib.hasInfix "Register-ArgumentCompleter -CommandName ${cmd}" windowsShellProfileText)
    nucleusCommands
  ) "Sync-ShellProfile.ps1 must register argument completers for all nucleus commands";

  # --- Windows pwsh reuses existing Resolve-NucleusRepoRoot ---
  test_windows_pwsh_reuses_repo_root_helper = assert' (lib.hasInfix "Resolve-NucleusRepoRoot" windowsShellProfileText) "Sync-ShellProfile.ps1 must reference Resolve-NucleusRepoRoot for dynamic completions";

  allTests = [
    test_zsh_completions_exist_for_all
    test_zsh_completions_have_compdef
    test_zsh_completions_installed_by_shell_nix
    test_windows_pwsh_has_completers_for_all
    test_windows_pwsh_reuses_repo_root_helper
  ];
in
{
  success = builtins.all (t: t == null) allTests;
  message = "Shell completion feature parity checks passed";
}
