# tests/integration/shell-shortcuts-tests.nix — Verify managed shell shortcut and command parity.

let
  lib = import <nixpkgs/lib>;
  aliasesText = builtins.readFile ../../src/modules/shell/aliases.nix;
  shellText = builtins.readFile ../../src/modules/shell.nix;
  # Shared shell-parity profile: single source consumed by pwsh.nix (POSIX,
  # eval-time embed) and Sync-ShellProfile.ps1 (Windows, runtime read-back).
  shellProfileText = builtins.readFile ../../src/scripts/shell/profile.ps1;
  macManualText = builtins.readFile ../../src/hosts/MacBook/MANUAL.md;
  nixosManualText = builtins.readFile ../../src/hosts/NixOS/MANUAL.md;
  windowsManualText = builtins.readFile ../../src/hosts/Windows/MANUAL.md;

  inherit (import ../lib.nix) assert';

  test_zsh_aliases_include_curated_git_shortcuts = assert' (
    lib.hasInfix ''"-gb" = "git branch";'' aliasesText
    && lib.hasInfix ''"-gcl" = "git clone";'' aliasesText
    && lib.hasInfix ''"-gf" = "git fetch";'' aliasesText
    && lib.hasInfix ''"-gl" = "git log --oneline --decorate --graph";'' aliasesText
    && lib.hasInfix ''"-gsw" = "git switch";'' aliasesText
  ) "aliases.nix must expose the curated git shortcut set";

  test_posix_pwsh_shortcuts_match_shell_aliases = assert' (
    lib.hasInfix "Add-ShellAlias '-gb' { & git branch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gcl' { & git clone @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gf' { & git fetch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gl' { & git log --oneline --decorate --graph @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gsw' { & git switch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-ni' { & bun install @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-nr' { & bun run @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-nx' { & bun x @Args }" shellProfileText
  ) "shared shell profile must mirror curated shell shortcuts, including bun shortcuts";

  test_windows_pwsh_shortcuts_match_shell_aliases = assert' (
    lib.hasInfix "Add-ShellAlias '-gb' { & git branch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gcl' { & git clone @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gf' { & git fetch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gl' { & git log --oneline --decorate --graph @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gsw' { & git switch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-ni' { & bun install @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-nr' { & bun run @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-nx' { & bun x @Args }" shellProfileText
  ) "shared shell profile must mirror curated shell shortcuts";

  test_posix_shell_exposes_managed_commands = assert' (
    lib.hasInfix ''"nucleus-ai"'' shellText
    && lib.hasInfix ''"nucleus-apply"'' shellText
    && lib.hasInfix ''"nucleus-bootstrap"'' shellText
    && lib.hasInfix ''"nucleus-check-pwsh"'' shellText
    && lib.hasInfix ''"nucleus-check-sh"'' shellText
    && lib.hasInfix ''"nucleus-cloud-setup"'' shellText
    && lib.hasInfix ''"nucleus-gc"'' shellText
    && lib.hasInfix ''"nucleus-gs-pdf-opt"'' shellText
    && lib.hasInfix ''"nucleus-health-check"'' shellText
    && lib.hasInfix ''"nucleus-replica-reset"'' shellText
    && lib.hasInfix ''"nucleus-replica-sync"'' shellText
    && lib.hasInfix ''"nucleus-update"'' shellText
    && lib.hasInfix ''"nucleus-vm"'' shellText
  ) "shell.nix must expose the managed nucleus command set";

  test_windows_shell_exposes_managed_commands = assert' (
    lib.hasInfix "function nucleus-ai" shellProfileText
    && lib.hasInfix "function nucleus-apply" shellProfileText
    && lib.hasInfix "function nucleus-bootstrap" shellProfileText
    && lib.hasInfix "function nucleus-check-pwsh" shellProfileText
    && lib.hasInfix "function nucleus-check-sh" shellProfileText
    && lib.hasInfix "function nucleus-cloud-setup" shellProfileText
    && lib.hasInfix "function nucleus-gc" shellProfileText
    && lib.hasInfix "function nucleus-gs-pdf-opt" shellProfileText
    && lib.hasInfix "function nucleus-health-check" shellProfileText
    && lib.hasInfix "function nucleus-replica-reset" shellProfileText
    && lib.hasInfix "function nucleus-replica-sync" shellProfileText
    && lib.hasInfix "function nucleus-update" shellProfileText
    && lib.hasInfix "function nucleus-vm" shellProfileText
  ) "shared shell profile must expose the managed nucleus command set";

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
      && lib.hasInfix "\`nucleus-ai\` — manage AI models (sync, list, status, endpoint, config)." text
      && lib.hasInfix "`nucleus-apply` — run the managed apply flow." text
      && lib.hasInfix "`nucleus-bootstrap` — run the managed bootstrap flow." text
      && lib.hasInfix "`nucleus-check-pwsh` — run PowerShell syntax checks." text
      && lib.hasInfix "`nucleus-check-sh` — run POSIX shell syntax checks." text
      && lib.hasInfix "`nucleus-cloud-setup` — configure required cloud remotes and re-run apply." text
      && lib.hasInfix "`nucleus-gc` — run the managed Nix garbage-collection flow." text
      && lib.hasInfix "`nucleus-gs-pdf-opt` — run the gs-pdf-opt script (optimize PDFs with Ghostscript)." text
      && lib.hasInfix "`nucleus-health-check` — run the managed repository health checks." text
      && lib.hasInfix "`nucleus-replica-sync` — run one-shot pull sync for enabled cloud replicas." text
      && lib.hasInfix "`nucleus-replica-reset` — clear local replica state without touching remote data." text
      && lib.hasInfix "`nucleus-update` — run the managed repository update flow." text
      && lib.hasInfix "`nucleus-vm setup` — build and provision VMs" text
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
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
  message = "Managed shell shortcut parity tests passed";
}
