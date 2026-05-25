# tests/nix/default-dev-tooling-tests.nix — Verify managed fallback tooling policy wiring.
#
# Guards the cross-host contract for repositories that do not ship direnv/Nix
# metadata: POSIX shells must expose the dedicated fallback tool bundle and
# Windows PowerShell must expose the managed default shell environment.
#
# Also guards the direnv-safe PATH wiring contract:
#   - POSIX: user-scope bin dirs declared via home.sessionPath (goes to
#     ~/.zshenv, sourced before ~/.zshrc where direnv hook lives) so the
#     entries survive direnv save/restore cycles.
#   - Windows: user-scope bin dirs prepended unconditionally (no Test-Path
#     guard) at the top of the managed block, before the direnv hook.
#
# Run with: nix-instantiate --eval tests/nix/default-dev-tooling-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  applyScriptText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  buildToolsPolicyText = builtins.readFile ../../.agents/instructions/build-tools-policy.instructions.md;
  cargoBinstallSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-CargoBinstallSetup.ps1;
  ciWorkflowText = builtins.readFile ../../.github/workflows/ci.yml;
  coreNixText = builtins.readFile ../../src/modules/core.nix;
  posixAgentsText = builtins.readFile ../../src/modules/agents.nix;
  posixPwshText = builtins.readFile ../../src/modules/pwsh.nix;
  posixShellText = builtins.readFile ../../src/modules/shell.nix;
  rustupSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-RustupSetup.ps1;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;

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

  # Verify that user-scope bin dirs are declared via home.sessionPath (POSIX)
  # and not via initContent PATH guards.  home.sessionPath writes to ~/.zshenv
  # which is sourced before ~/.zshrc (where direnv hook lives), making the
  # entries immune to direnv save/restore cycles.
  test_posix_uses_session_path_for_user_bins =
    assert'
      (
        (lib.hasInfix "home.sessionPath" posixShellText)
        && (lib.hasInfix "/.bun/bin" posixShellText)
        && (lib.hasInfix "/.cargo/bin" posixShellText)
        && (lib.hasInfix "/.local/bin" posixShellText)
        # Must NOT have old-style guarded PATH export in initContent.
        && !(lib.hasInfix "[[ -d \"$HOME/.bun/bin\"" posixShellText)
        && !(lib.hasInfix "[[ -d \"$HOME/.cargo/bin\"" posixShellText)
        && !(lib.hasInfix "[[ -d \"$HOME/.local/bin\"" posixShellText)
      )
      "shell.nix must declare user-scope bin dirs via home.sessionPath (direnv-safe), not initContent PATH guards";

  # Verify that Windows managed block adds user-scope bin dirs unconditionally
  # (no Test-Path guard) and before the direnv hook so the entries are in the
  # environment direnv captures and restores.
  test_windows_unconditional_user_bin_path =
    assert'
      (
        (lib.hasInfix "\\.bun\\bin" windowsShellProfileText)
        && (lib.hasInfix "\\.cargo\\bin" windowsShellProfileText)
        # Must NOT use Test-Path guard for these entries (would silently drop them
        # when the dir is newly created and a direnv cycle has already run).
        && !(lib.hasInfix "Test-Path $bunBinDir" windowsShellProfileText)
        && !(lib.hasInfix "Test-Path $cargoBinDir" windowsShellProfileText)
      )
      "Sync-ShellProfile.ps1 must prepend .bun\\bin and .cargo\\bin unconditionally (no Test-Path guard) for direnv reliability";

  # Verify that __nucleus_run_managed_dev_tool probes tool availability via
  # command -v before routing through the direnv context.  This mirrors the
  # PowerShell Invoke-NucleusManagedDevTool pattern so projects that do not
  # include a managed tool in their devShell fall through to
  # NUCLEUS_DEFAULT_DEV_BIN instead of failing with "command not found".
  test_posix_shell_probes_tool_in_direnv = assert' (lib.hasInfix "command -v \"$_tool_name\"" posixShellText) "shell.nix must probe tool availability (command -v) in direnv context before routing, so projects lacking the managed tool fall through to NUCLEUS_DEFAULT_DEV_BIN";

  # Verify that the managed dev tool fallback sets LIBRARY_PATH to include the
  # Nix-managed libiconv on macOS so cargo/rustc can build C-dependent crates
  # (e.g. openssl-sys) outside a devShell without a linker "library not found"
  # error.  LIBRARY_PATH must only be set for the subprocess (env prefix), not
  # permanently exported to the interactive shell.
  test_posix_shell_prepends_libiconv_in_fallback =
    assert'
      (
        (lib.hasInfix "NUCLEUS_LIBICONV_LIB" posixShellText) && (lib.hasInfix "LIBRARY_PATH" posixShellText)
      )
      "shell.nix must define NUCLEUS_LIBICONV_LIB and set LIBRARY_PATH in the fallback for macOS cargo/rustc builds";

  # Verify that POSIX hosts install cargo from nixpkgs directly (pkgs.cargo),
  # NOT via rustup.  rustup is Windows-only; on POSIX, Nix provides cargo for
  # system package management (cargo-binstall, cargo install).  The
  # installRustupToolchains hook must be absent from agents.nix to prevent
  # accidental reimplementation.
  test_posix_rustup_sets_default_stable =
    assert'
      (
        (lib.hasInfix "pkgs.cargo" coreNixText)
        && !(lib.hasInfix "pkgs.rustup" coreNixText)
        && !(lib.hasInfix "installRustupToolchains" posixAgentsText)
      )
      "POSIX hosts must use pkgs.cargo from nixpkgs (not pkgs.rustup) and agents.nix must not contain installRustupToolchains";

  # Same guard for the Windows equivalent.
  test_windows_rustup_sets_default_stable = assert' (lib.hasInfix "rustup default none" rustupSetupText) "Invoke-RustupSetup.ps1 must call 'rustup default none' after toolchain convergence";

  # Verify that the cargo package convergence uses `cargo install --list` as
  # the authoritative installed-set source, which covers BOTH plain
  # `cargo install` packages AND `cargo-binstall` packages in one pass.
  # The removal side uses `cargo uninstall`, which handles both origins.
  test_posix_cargo_prunes_both_install_and_binstall =
    assert'
      (
        (lib.hasInfix "cargo install --list" posixAgentsText)
        && (lib.hasInfix "cargo uninstall" posixAgentsText)
      )
      "agents.nix must use 'cargo install --list' + 'cargo uninstall' to prune both cargo install and cargo-binstall packages";

  test_windows_cargo_prunes_both_install_and_binstall =
    assert'
      (
        (lib.hasInfix "cargo install --list" cargoBinstallSetupText)
        && (lib.hasInfix "cargo uninstall" cargoBinstallSetupText)
      )
      "Invoke-CargoBinstallSetup.ps1 must use 'cargo install --list' + 'cargo uninstall' to prune both cargo install and cargo-binstall packages";

  allTests = [
    test_posix_shell_exports_fallback_bundle
    test_posix_pwsh_uses_fallback_bundle
    test_windows_shell_uses_default_env
    test_windows_apply_wires_shell_profile_sync
    test_policy_docs_capture_fallback
    test_ci_runs_this_suite
    test_posix_uses_session_path_for_user_bins
    test_windows_unconditional_user_bin_path
    test_posix_shell_probes_tool_in_direnv
    test_posix_shell_prepends_libiconv_in_fallback
    test_posix_rustup_sets_default_stable
    test_windows_rustup_sets_default_stable
    test_posix_cargo_prunes_both_install_and_binstall
    test_windows_cargo_prunes_both_install_and_binstall
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
    "7: POSIX zsh uses home.sessionPath for user-scope bin dirs (direnv-safe)"
    "8: Windows managed block prepends user-scope bin dirs unconditionally"
    "9: POSIX zsh probes tool availability in direnv context before routing"
    "10: POSIX zsh fallback sets LIBRARY_PATH for macOS libiconv (cargo/rustc builds)"
    "11: POSIX hosts use pkgs.cargo from nixpkgs (not pkgs.rustup)"
    "12: Windows Invoke-RustupSetup calls rustup default none"
    "13: POSIX cargo convergence prunes both cargo install and cargo-binstall packages"
    "14: Windows cargo convergence prunes both cargo install and cargo-binstall packages"
  ];
}
