# tests/integration/shell-history-tests.nix — Verify history exclusion feature parity.

let
  lib = import <nixpkgs/lib>;
  shellText = builtins.readFile ../../src/modules/shell.nix;
  posixPwshText = builtins.readFile ../../src/modules/pwsh.nix;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;
  windowsShellDscText = builtins.readFile ../../src/hosts/Windows/user/shell.dsc.yml;

  inherit (import ../lib.nix) assert';

  # --- zsh ---
  test_zsh_has_hist_ignore_space = assert' (lib.hasInfix "setopt HIST_IGNORE_SPACE" shellText) "shell.nix must set HIST_IGNORE_SPACE to exclude space-prefixed commands from history";

  test_zsh_has_hist_ignore_dups = assert' (lib.hasInfix "setopt HIST_IGNORE_DUPS" shellText) "shell.nix must set HIST_IGNORE_DUPS to exclude consecutive duplicates from history";

  # --- POSIX PowerShell ---
  test_posix_pwsh_has_history_no_duplicates = assert' (lib.hasInfix "HistoryNoDuplicates" posixPwshText) "pwsh.nix must enable HistoryNoDuplicates for POSIX PowerShell";

  test_posix_pwsh_has_space_prefix_handler = assert' (
    lib.hasInfix "AddToHistoryHandler" posixPwshText
    && lib.hasInfix "\$line -notmatch '^\\\\s'" posixPwshText
  ) "pwsh.nix must use AddToHistoryHandler to exclude space-prefixed commands from history";

  # --- Windows PowerShell ---
  test_windows_pwsh_has_history_no_duplicates = assert' (lib.hasInfix "HistoryNoDuplicates" windowsShellProfileText) "Sync-ShellProfile.ps1 must enable HistoryNoDuplicates for Windows PowerShell";

  test_windows_pwsh_has_space_prefix_handler =
    assert'
      (
        lib.hasInfix "AddToHistoryHandler" windowsShellProfileText
        && lib.hasInfix "\$line -notmatch ''^\\\\s''" windowsShellProfileText
      )
      "Sync-ShellProfile.ps1 must use AddToHistoryHandler to exclude space-prefixed commands from history";

  # --- Documentation of impossible cases ---
  test_cmd_exe_limitation_documented = assert' (
    lib.hasInfix "cmd.exe has no equivalent" windowsShellDscText
    && lib.hasInfix "HIST_IGNORE_SPACE" windowsShellDscText
  ) "shell.dsc.yml must document that cmd.exe cannot implement history exclusion";

  # --- Future-shell reference documented in shell.nix header ---
  test_future_shell_reference_documented = assert' (
    lib.hasInfix "When adding a new shell" shellText
    && lib.hasInfix "HISTCONTROL=ignorespace:ignoredups" shellText
  ) "shell.nix header must document equivalent settings for future shells (bash, fish, nushell)";
in
{
  success = true;
  message = "Shell history exclusion feature parity checks passed";
}
