# tests/integration/shell-shortcuts-tests.nix — Verify managed shell shortcut and command parity.

let
  lib = import <nixpkgs/lib>;
  aliasesText = builtins.readFile ../../src/modules/shell/aliases.nix;
  flakeText = builtins.readFile ../../src/flake.nix;
  # Shared shell-parity profile: single source consumed by pwsh.nix (POSIX,
  # eval-time embed) and Sync-ShellProfile.ps1 (Windows, runtime read-back).
  shellProfileText = builtins.readFile ../../src/scripts/shell/profile.ps1;
  macManualText = builtins.readFile ../../src/hosts/MacBook/MANUAL.md;
  nixosManualText = builtins.readFile ../../src/hosts/NixOS/MANUAL.md;
  windowsManualText = builtins.readFile ../../src/hosts/Windows/MANUAL.md;
  scriptsBundleText = builtins.readFile ../../src/modules/lib/scripts-bundle.nix;
  scriptTreeText = builtins.readFile ../../src/modules/lib/script-tree.nix;

  inherit (import ../lib.nix) assert';

  test_zsh_aliases_include_curated_git_shortcuts = assert' (
    lib.hasInfix ''"-gb" = "git branch";'' aliasesText
    && lib.hasInfix ''"-gcl" = "git clone";'' aliasesText
    && lib.hasInfix ''"-gf" = "git fetch";'' aliasesText
    && lib.hasInfix ''"-gl" = "git log --oneline --decorate --graph";'' aliasesText
    && lib.hasInfix ''"-gsw" = "git switch";'' aliasesText
  ) "aliases.nix must expose the curated git shortcut set";

  test_zsh_aliases_include_bun_shortcuts = assert' (builtins.all
    (aliasLine: lib.hasInfix aliasLine aliasesText)
    [
      ''"-n" = "bun";''
      ''"-na" = "bun add";''
      ''"-nb" = "bun build";''
      ''"-nc" = "bun create";''
      ''"-nci" = "bun ci";''
      ''"-ncl" = "bun clean";''
      ''"-nf" = "bun fmt";''
      ''"-nff" = "bun format";''
      ''"-ni" = "bun install";''
      ''"-nl" = "bun link";''
      ''"-no" = "bun outdated";''
      ''"-nr" = "bun run";''
      ''"-nrm" = "bun remove";''
      ''"-nt" = "bun test";''
      ''"-nu" = "bun update";''
      ''"-nup" = "bun upgrade";''
      ''"-nw" = "bun why";''
      ''"-nx" = "bun x";''
    ]
  ) "aliases.nix must expose the curated bun shortcut set";

  test_posix_pwsh_shortcuts_match_shell_aliases = assert' (
    lib.hasInfix "Add-ShellAlias '-gb' { & git branch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gcl' { & git clone @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gf' { & git fetch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gl' { & git log --oneline --decorate --graph @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gsw' { & git switch @Args }" shellProfileText
    && builtins.all (aliasLine: lib.hasInfix aliasLine shellProfileText) [
      "Add-ShellAlias '-n' { & bun @Args }"
      "Add-ShellAlias '-na' { & bun add @Args }"
      "Add-ShellAlias '-nb' { & bun build @Args }"
      "Add-ShellAlias '-nc' { & bun create @Args }"
      "Add-ShellAlias '-nci' { & bun ci @Args }"
      "Add-ShellAlias '-ncl' { & bun clean @Args }"
      "Add-ShellAlias '-nf' { & bun fmt @Args }"
      "Add-ShellAlias '-nff' { & bun format @Args }"
      "Add-ShellAlias '-ni' { & bun install @Args }"
      "Add-ShellAlias '-nl' { & bun link @Args }"
      "Add-ShellAlias '-no' { & bun outdated @Args }"
      "Add-ShellAlias '-nr' { & bun run @Args }"
      "Add-ShellAlias '-nrm' { & bun remove @Args }"
      "Add-ShellAlias '-nt' { & bun test @Args }"
      "Add-ShellAlias '-nu' { & bun update @Args }"
      "Add-ShellAlias '-nup' { & bun upgrade @Args }"
      "Add-ShellAlias '-nw' { & bun why @Args }"
      "Add-ShellAlias '-nx' { & bun x @Args }"
    ]
  ) "shared shell profile must mirror curated shell shortcuts, including bun shortcuts";

  test_windows_pwsh_shortcuts_match_shell_aliases = assert' (
    lib.hasInfix "Add-ShellAlias '-gb' { & git branch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gcl' { & git clone @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gf' { & git fetch @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gl' { & git log --oneline --decorate --graph @Args }" shellProfileText
    && lib.hasInfix "Add-ShellAlias '-gsw' { & git switch @Args }" shellProfileText
    && builtins.all (aliasLine: lib.hasInfix aliasLine shellProfileText) [
      "Add-ShellAlias '-n' { & bun @Args }"
      "Add-ShellAlias '-na' { & bun add @Args }"
      "Add-ShellAlias '-nb' { & bun build @Args }"
      "Add-ShellAlias '-nc' { & bun create @Args }"
      "Add-ShellAlias '-nci' { & bun ci @Args }"
      "Add-ShellAlias '-ncl' { & bun clean @Args }"
      "Add-ShellAlias '-nf' { & bun fmt @Args }"
      "Add-ShellAlias '-nff' { & bun format @Args }"
      "Add-ShellAlias '-ni' { & bun install @Args }"
      "Add-ShellAlias '-nl' { & bun link @Args }"
      "Add-ShellAlias '-no' { & bun outdated @Args }"
      "Add-ShellAlias '-nr' { & bun run @Args }"
      "Add-ShellAlias '-nrm' { & bun remove @Args }"
      "Add-ShellAlias '-nt' { & bun test @Args }"
      "Add-ShellAlias '-nu' { & bun update @Args }"
      "Add-ShellAlias '-nup' { & bun upgrade @Args }"
      "Add-ShellAlias '-nw' { & bun why @Args }"
      "Add-ShellAlias '-nx' { & bun x @Args }"
    ]
  ) "shared shell profile must mirror curated shell shortcuts";

  test_write_nucleus_shell_application_defaults_bundle_false = assert' (
    lib.hasInfix "bundleDefault ? false" flakeText
    && lib.hasInfix "scripts-bundle.nix" flakeText
    && lib.hasInfix "ln -s \${thisScriptsBundle}/scripts" flakeText
    && lib.hasInfix "ln -s \${thisScriptTree}/src" flakeText
    && lib.hasInfix "&& pwd)/\${scriptName}.sh" flakeText
    && !lib.hasInfix "pwd -P)/\${scriptName}.sh" flakeText
  ) "writeNucleusShellApplication must default bundleDefault to false and symlink shared bundles";

  test_script_tree_and_scripts_bundle_skip_build_time_shellcheck = assert' (
    !lib.hasInfix "shellcheck" scriptTreeText
    && !lib.hasInfix "shellcheck" scriptsBundleText
    && lib.hasInfix "nucleus-scripts-bundle" scriptsBundleText
    && lib.hasInfix "nucleus-script-tree" scriptTreeText
    && lib.hasInfix "ln -s \${scriptTree}/src" scriptsBundleText
  ) "shared script bundles must not shellcheck at derivation build time";

  test_posix_shell_exposes_managed_commands = assert' (
    lib.hasInfix "nucleusApp = args: writeNucleusShellApplication pkgs (args // { bundleDefault = true; })" flakeText
    && lib.hasInfix "nucleus-ai = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-apply = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-bootstrap = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-check-pwsh = mkCheckPwshPackage pkgs;" flakeText
    && lib.hasInfix "nucleus-check-sh = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-cloud-setup = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-gc = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-gs-pdf-opt = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-health-check = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-replica-reset = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-replica-sync = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-update = nucleusApp {" flakeText
    && lib.hasInfix "nucleus-vm = nucleusApp {" flakeText
  ) "flake.nix must expose the managed nucleus command set";

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
      lib.hasInfix "`-gsw` — git commands" text
      && lib.hasInfix "`-n`, `-na`, `-nb`, `-nc`, `-nci`, `-ncl`, `-nf`, `-nff`, `-ni`, `-nl`, `-no`, `-nr`, `-nrm`, `-nt`, `-nu`, `-nup`, `-nw`, `-nx` — bun commands" text
      && lib.hasInfix "`-la`, `-ll` — `eza -la`" text
      && lib.hasInfix "`-v` — `nvim`" text
      && lib.hasInfix "`nucleus-ai` — manage AI models (sync, list, status, endpoint, config)" text
      && lib.hasInfix "`nucleus-apply` — apply configuration" text
      && lib.hasInfix "`nucleus-bootstrap` — bootstrap system" text
      && lib.hasInfix "`nucleus-check-pwsh` — check PowerShell syntax" text
      && lib.hasInfix "`nucleus-check-sh` — check POSIX shell syntax" text
      && lib.hasInfix "`nucleus-cloud-setup` — configure cloud remotes and re-apply" text
      && lib.hasInfix "`nucleus-gc` — run Nix garbage collection" text
      && lib.hasInfix "`nucleus-gs-pdf-opt` — optimize PDF files with Ghostscript" text
      && lib.hasInfix "`nucleus-health-check` — run health checks" text
      && lib.hasInfix "`nucleus-replica-sync` — pull cloud replicas" text
      && lib.hasInfix "`nucleus-replica-reset` — reset local replica state" text
      && lib.hasInfix "`nucleus-update` — update repository" text
      && lib.hasInfix "`nucleus-vm setup` — build and provision VMs from `src/modules/VMs.json`" text
    )
    [
      macManualText
      nixosManualText
      windowsManualText
    ]
  ) "All host manuals must document the curated shortcut and nucleus command sets";

  allTests = [
    test_zsh_aliases_include_curated_git_shortcuts
    test_zsh_aliases_include_bun_shortcuts
    test_posix_pwsh_shortcuts_match_shell_aliases
    test_windows_pwsh_shortcuts_match_shell_aliases
    test_write_nucleus_shell_application_defaults_bundle_false
    test_script_tree_and_scripts_bundle_skip_build_time_shellcheck
    test_posix_shell_exposes_managed_commands
    test_windows_shell_exposes_managed_commands
    test_manuals_document_curated_shortcuts_and_commands
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "Managed shell shortcut parity tests passed";
}
