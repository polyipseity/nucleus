# tests/src/shell-shortcuts-tests.nix — Verify managed shell shortcut and command parity.
#
# Guards the cross-host shell contract so zsh, POSIX PowerShell, Windows
# PowerShell, and host manuals stay aligned on the curated shortcut surface.

{
  lib ? import <nixpkgs/lib>,
}:
let
  aliasesText = builtins.readFile ../../src/modules/shell/aliases.nix;
  shellText = builtins.readFile ../../src/modules/shell.nix;
  posixPwshText = builtins.readFile ../../src/modules/pwsh.nix;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;
  macManualText = builtins.readFile ../../src/hosts/MacBook/MANUAL.md;
  nixosManualText = builtins.readFile ../../src/hosts/NixOS/MANUAL.md;
  windowsManualText = builtins.readFile ../../src/hosts/Windows/MANUAL.md;

  assert' = cond: msg: if !cond then throw msg else null;

  test_zsh_aliases_include_curated_git_shortcuts = assert' (
    lib.hasInfix ''"-gb" = "git branch";'' aliasesText
    && lib.hasInfix ''"-gcl" = "git clone";'' aliasesText
    && lib.hasInfix ''"-gf" = "git fetch";'' aliasesText
    && lib.hasInfix ''"-gl" = "git log --oneline --decorate --graph";'' aliasesText
    && lib.hasInfix ''"-gsw" = "git switch";'' aliasesText
  ) "aliases.nix must expose the curated git shortcut set";

  test_posix_pwsh_shortcuts_match_shell_aliases = assert' (
    lib.hasInfix "function -gb { & git branch @Args }" posixPwshText
    && lib.hasInfix "function -gcl { & git clone @Args }" posixPwshText
    && lib.hasInfix "function -gf { & git fetch @Args }" posixPwshText
    && lib.hasInfix "function -gl { & git log --oneline --decorate --graph @Args }" posixPwshText
    && lib.hasInfix "function -gsw { & git switch @Args }" posixPwshText
    && lib.hasInfix "function -ni { & bun install @Args }" posixPwshText
    && lib.hasInfix "function -nr { & bun run @Args }" posixPwshText
    && lib.hasInfix "function -nx { & bun x @Args }" posixPwshText
  ) "pwsh.nix must mirror curated shell shortcuts, including bun shortcuts";

  test_windows_pwsh_shortcuts_match_shell_aliases = assert' (
    lib.hasInfix "function -gb { & git branch @Args }" windowsShellProfileText
    && lib.hasInfix "function -gcl { & git clone @Args }" windowsShellProfileText
    && lib.hasInfix "function -gf { & git fetch @Args }" windowsShellProfileText
    && lib.hasInfix "function -gl { & git log --oneline --decorate --graph @Args }" windowsShellProfileText
    && lib.hasInfix "function -gsw { & git switch @Args }" windowsShellProfileText
    && lib.hasInfix "function -ni { & bun install @Args }" windowsShellProfileText
    && lib.hasInfix "function -nr { & bun run @Args }" windowsShellProfileText
    && lib.hasInfix "function -nx { & bun x @Args }" windowsShellProfileText
  ) "Windows shell profile must mirror curated shell shortcuts";

  test_posix_shell_exposes_managed_commands = assert' (
    lib.hasInfix ''"nucleus-ai-sync"'' shellText
    && lib.hasInfix ''"nucleus-apply"'' shellText
    && lib.hasInfix ''"nucleus-bootstrap"'' shellText
    && lib.hasInfix ''"nucleus-check-pwsh"'' shellText
    && lib.hasInfix ''"nucleus-check-sh"'' shellText
    && lib.hasInfix ''"nucleus-cloud-setup"'' shellText
    && lib.hasInfix ''"nucleus-gc"'' shellText
    && lib.hasInfix ''"nucleus-health-check"'' shellText
    && lib.hasInfix ''"nucleus-replica-reset"'' shellText
    && lib.hasInfix ''"nucleus-replica-sync"'' shellText
    && lib.hasInfix ''"nucleus-update"'' shellText
    && lib.hasInfix ''"nucleus-vm-setup"'' shellText
  ) "shell.nix must expose the managed nucleus command set";

  test_windows_shell_exposes_managed_commands = assert' (
    lib.hasInfix "function nucleus-ai-sync" windowsShellProfileText
    && lib.hasInfix "function nucleus-apply" windowsShellProfileText
    && lib.hasInfix "function nucleus-bootstrap" windowsShellProfileText
    && lib.hasInfix "function nucleus-check-pwsh" windowsShellProfileText
    && lib.hasInfix "function nucleus-check-sh" windowsShellProfileText
    && lib.hasInfix "function nucleus-cloud-setup" windowsShellProfileText
    && lib.hasInfix "function nucleus-gc" windowsShellProfileText
    && lib.hasInfix "function nucleus-health-check" windowsShellProfileText
    && lib.hasInfix "function nucleus-replica-reset" windowsShellProfileText
    && lib.hasInfix "function nucleus-replica-sync" windowsShellProfileText
    && lib.hasInfix "function nucleus-update" windowsShellProfileText
    && lib.hasInfix "function nucleus-vm-setup" windowsShellProfileText
  ) "Windows shell profile must expose the managed nucleus command set";

  test_manuals_document_curated_shortcuts_and_commands = assert' (builtins.all
    (
      text:
      lib.hasInfix "`-gb` — run `git branch`." text
      && lib.hasInfix "`-gcl` — run `git clone`." text
      && lib.hasInfix "`-gf` — run `git fetch`." text
      && lib.hasInfix "`-gl` — run `git log --oneline --decorate --graph`." text
      && lib.hasInfix "`-gsw` — run `git switch`." text
      && lib.hasInfix "`-ni` — run `bun install`." text
      && lib.hasInfix "`-nr` — run `bun run`." text
      && lib.hasInfix "`-nx` — run `bun x`." text
      && lib.hasInfix "`nucleus-ai-sync` — run the managed AI model sync flow." text
      && lib.hasInfix "`nucleus-apply` — run the managed apply flow." text
      && lib.hasInfix "`nucleus-bootstrap` — run the managed bootstrap flow." text
      && lib.hasInfix "`nucleus-check-pwsh` — run PowerShell syntax checks." text
      && lib.hasInfix "`nucleus-check-sh` — run POSIX shell syntax checks." text
      && lib.hasInfix "`nucleus-cloud-setup` — configure required cloud remotes and re-run apply." text
      && lib.hasInfix "`nucleus-gc` — run the managed Nix garbage-collection flow." text
      && lib.hasInfix "`nucleus-health-check` — run the managed repository health checks." text
      && lib.hasInfix "`nucleus-replica-sync` — run one-shot pull sync for enabled cloud replicas." text
      && lib.hasInfix "`nucleus-replica-reset` — clear local replica state without touching remote data." text
      && lib.hasInfix "`nucleus-update` — run the managed repository update flow." text
      && lib.hasInfix "`nucleus-vm-setup` — build (if needed) and provision" text
    )
    [
      macManualText
      nixosManualText
      windowsManualText
    ]
  ) "All host manuals must document the curated shortcut and nucleus command sets";

  allTests = [
    test_zsh_aliases_include_curated_git_shortcuts
    test_posix_pwsh_shortcuts_match_shell_aliases
    test_windows_pwsh_shortcuts_match_shell_aliases
    test_posix_shell_exposes_managed_commands
    test_windows_shell_exposes_managed_commands
    test_manuals_document_curated_shortcuts_and_commands
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "Managed shell shortcut parity tests passed";
}
