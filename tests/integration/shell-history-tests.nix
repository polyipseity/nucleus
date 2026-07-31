# tests/integration/shell-history-tests.nix — Verify history exclusion feature parity.

let
  lib = import <nixpkgs/lib>;
  shellText = builtins.readFile ../../src/modules/shell.nix;
  zshText = builtins.readFile ../../src/scripts/shell/init.zsh;
  posixPwshText = builtins.readFile ../../src/scripts/shell/profile.ps1;
  windowsShellProfileText = builtins.readFile ../../src/scripts/shell/profile.ps1;
  windowsShellDscText = builtins.readFile ../../src/hosts/Windows/user/shell.dsc.yml;

  inherit (import ../lib.nix) assert';

  # --- zsh ---
  test_zsh_has_hist_ignore_space = assert' (lib.hasInfix "setopt HIST_IGNORE_SPACE" zshText) "init.zsh must set HIST_IGNORE_SPACE to exclude space-prefixed commands from history";

  test_zsh_has_hist_ignore_dups = assert' (lib.hasInfix "setopt HIST_IGNORE_DUPS" zshText) "init.zsh must set HIST_IGNORE_DUPS to exclude consecutive duplicates from history";

  # --- POSIX PowerShell (shared profile.ps1, consumed by pwsh.nix) ---
  test_posix_pwsh_has_history_no_duplicates = assert' (lib.hasInfix "HistoryNoDuplicates" posixPwshText) "profile.ps1 must enable HistoryNoDuplicates for POSIX PowerShell";

  test_posix_pwsh_has_space_prefix_handler = assert' (
    lib.hasInfix "AddToHistoryHandler" posixPwshText
    && lib.hasInfix "\$line -notmatch '^\\s'" posixPwshText
  ) "profile.ps1 must use AddToHistoryHandler to exclude space-prefixed commands from history";

  # --- Windows PowerShell (same shared profile.ps1) ---
  test_windows_pwsh_has_history_no_duplicates = assert' (lib.hasInfix "HistoryNoDuplicates" windowsShellProfileText) "profile.ps1 must enable HistoryNoDuplicates for Windows PowerShell";

  test_windows_pwsh_has_space_prefix_handler = assert' (
    lib.hasInfix "AddToHistoryHandler" windowsShellProfileText
    && lib.hasInfix "\$line -notmatch '^\\s'" windowsShellProfileText
  ) "profile.ps1 must use AddToHistoryHandler to exclude space-prefixed commands from history";

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
builtins.seq
  (builtins.deepSeq {
    inherit
      test_zsh_has_hist_ignore_space
      test_zsh_has_hist_ignore_dups
      test_posix_pwsh_has_history_no_duplicates
      test_posix_pwsh_has_space_prefix_handler
      test_windows_pwsh_has_history_no_duplicates
      test_windows_pwsh_has_space_prefix_handler
      test_cmd_exe_limitation_documented
      test_future_shell_reference_documented
      ;
  } null)
  {
    success = true;
    testCount = 8;
    message = "All 8 shell-history tests passed";
  }
