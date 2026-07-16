# tests/integration/default-dev-tooling-tests.nix — Verify managed fallback tooling policy wiring.
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
{
  lib ? import <nixpkgs/lib>,
}:
let
  applyScriptText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  buildToolsPolicyText = builtins.readFile ../../.agents/instructions/package-installation-scope.instructions.md;
  cargoBinstallSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-CargoBinstallSetup.ps1;
  ciWorkflowText = builtins.readFile ../../.github/workflows/ci.yml;
  coreNixText = builtins.readFile ../../src/modules/core.nix;
  flakeNixText = builtins.readFile ../../src/flake.nix;
  posixAgentsText = builtins.readFile ../../src/modules/agents.nix;
  posixPwshText = builtins.readFile ../../src/modules/pwsh.nix;
  posixShellText = builtins.readFile ../../src/modules/shell.nix;
  rustToolchainText = builtins.readFile ../../rust-toolchain.toml;
  rustupSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-RustupSetup.ps1;
  uvSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-UvSetup.ps1;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;

  inherit (import ../lib.nix) assert';

  test_posix_shell_exports_fallback_bundle = assert' (
    (lib.hasInfix "default-dev-tools" posixShellText)
    && (lib.hasInfix "__nucleus_run_managed_dev_tool" posixShellText)
  ) "shell.nix must publish the fallback tool bundle and helper for unmanaged repositories";

  test_posix_pwsh_uses_fallback_bundle = assert' (
    (lib.hasInfix "default-dev-tools" posixPwshText)
    && (lib.hasInfix "Invoke-NucleusManagedDevTool" posixPwshText)
  ) "pwsh.nix must publish and consume the fallback tool bundle for unmanaged repositories";

  test_windows_shell_uses_default_env = assert' (lib.hasInfix "Invoke-NucleusManagedDevTool" windowsShellProfileText) "Sync-ShellProfile.ps1 must expose the managed default shell environment on Windows";

  test_windows_apply_wires_shell_profile_sync = assert' (
    (lib.hasInfix "Sync-ShellProfile.ps1" applyScriptText)
    && (lib.hasInfix "Sync-ShellProfile -Enabled:$EnableShellParity" applyScriptText)
  ) "Windows apply.ps1 must load and execute Sync-ShellProfile so fallback shell policy is enforced";

  test_policy_docs_capture_fallback = assert' (lib.hasInfix "Invoke-NucleusManagedDevTool" buildToolsPolicyText) "Build tools policy instructions must document the managed fallback environment";

  test_ci_runs_this_suite = assert' (lib.hasInfix "tests/integration/default-dev-tooling-tests.nix" ciWorkflowText) "CI must execute the managed fallback tooling tests";

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
  # include a managed tool in their devShell fall through to the managed
  # default toolchain (defaultDevTools) instead of failing with "command not found".
  test_posix_shell_probes_tool_in_direnv = assert' (lib.hasInfix "command -v \"$_tool_name\"" posixShellText) "shell.nix must probe tool availability (command -v) in direnv context before routing, so projects lacking the managed tool fall through to the fallback tool bundle";

  # Verify that POSIX hosts use pkgs.rustup (not pkgs.cargo from nixpkgs) so
  # that all platforms are unified on rustup for Rust toolchain management.
  # agents.nix must contain initRustup to set up rustup on POSIX hosts.
  test_posix_uses_rustup_not_cargo_nix =
    assert'
      (
        !(lib.hasInfix "pkgs.cargo" coreNixText)
        && (lib.hasInfix "pkgs.rustup" coreNixText)
        && (lib.hasInfix "initRustup" posixAgentsText)
      )
      "POSIX hosts must use pkgs.rustup (not pkgs.cargo from nixpkgs) and agents.nix must contain initRustup";

  # Verify that the POSIX initRustup activation calls 'rustup default none' to
  # enforce project-local toolchain selection, matching Invoke-RustupSetup.ps1
  # on Windows.
  test_posix_init_rustup_sets_default_none = assert' (lib.hasInfix "rustup default none" posixAgentsText) "agents.nix initRustup must call 'rustup default none' to enforce project-local toolchain selection on POSIX hosts";

  # Verify that POSIX shell.nix does NOT include NUCLEUS_LIBICONV_LIB since
  # Nix-managed cargo/rustc are no longer in the fallback bundle.  The devShell
  # handles libiconv via buildInputs in flake.nix; shell profile injection is
  # no longer needed.
  test_posix_shell_no_libiconv_fallback =
    assert' (!(lib.hasInfix "NUCLEUS_LIBICONV_LIB" posixShellText))
      "shell.nix must NOT contain NUCLEUS_LIBICONV_LIB after removal of Nix-managed cargo/rustc from the fallback bundle";

  # Verify that the Windows Invoke-RustupSetup.ps1 calls 'rustup default none'
  # after toolchain installation so per-project toolchains are always
  # authoritative on Windows (mirrors initRustup behavior on POSIX).
  test_windows_rustup_sets_default_stable = assert' (lib.hasInfix "rustup default none" rustupSetupText) "Invoke-RustupSetup.ps1 must call 'rustup default none' after toolchain convergence";

  # Verify that the cargo package convergence uses `cargo +stable install --list`
  # as the authoritative installed-set source (rustup default is none on POSIX;
  # +stable selects the installed stable toolchain explicitly).
  # The removal side uses `cargo +stable uninstall`, which handles both origins.
  test_posix_cargo_prunes_both_install_and_binstall =
    assert'
      (
        (lib.hasInfix "cargo +stable install --list" posixAgentsText)
        && (lib.hasInfix "cargo +stable uninstall" posixAgentsText)
      )
      "agents.nix must use 'cargo +stable install --list' + 'cargo +stable uninstall' to prune both cargo install and cargo-binstall packages";

  test_windows_cargo_prunes_both_install_and_binstall =
    assert'
      (
        (lib.hasInfix "cargo install --list" cargoBinstallSetupText)
        && (lib.hasInfix "cargo uninstall" cargoBinstallSetupText)
      )
      "Invoke-CargoBinstallSetup.ps1 must use 'cargo install --list' + 'cargo uninstall' to prune both cargo install and cargo-binstall packages";

  # Verify uv prune parsing is strict and resilient on both POSIX and Windows:
  # only "name vX.Y.Z" lines are parsed and uninstall/install tokens are
  # validated before command invocation.
  test_uv_prune_parsing_and_validation_parity =
    assert'
      (
        (lib.hasInfix "awk '/^[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]+v[0-9]/{print $1}'" posixAgentsText)
        && (lib.hasInfix "skipping invalid uninstall token" posixAgentsText)
        && (lib.hasInfix "skipping invalid install token" posixAgentsText)
        && (lib.hasInfix "-match '^[A-Za-z0-9][A-Za-z0-9._-]*\\s+v\\d'" uvSetupText)
        && (lib.hasInfix "skipping invalid uninstall token" uvSetupText)
        && (lib.hasInfix "skipping invalid install token" uvSetupText)
      )
      "POSIX and Windows uv convergence scripts must strictly parse uv tool list output and validate uninstall/install tokens";

  # Verify that the POSIX devShell uses rust-overlay so that projects can pin
  # their Rust toolchain via rust-toolchain.toml.  rust-overlay assembles a
  # Nix-patched toolchain for devShells; the system interactive shell uses
  # pkgs.rustup for Rust management on POSIX hosts.
  test_posix_devshell_uses_rust_overlay =
    assert'
      (
        (lib.hasInfix "rust-overlay" flakeNixText)
        && (lib.hasInfix "fromRustupToolchainFile" flakeNixText)
        && (lib.hasInfix "rust-bin" flakeNixText)
      )
      "flake.nix devShell must use rust-overlay with fromRustupToolchainFile for per-project Rust toolchain management";

  # Verify that the nucleus repo has a rust-toolchain.toml at its root so the
  # POSIX devShell has a pinned stable toolchain (the file-present branch of the
  # builtins.pathExists conditional is exercised on the nucleus repo itself).
  test_rust_toolchain_toml_exists_and_is_stable =
    assert' ((lib.hasInfix "channel" rustToolchainText) && (lib.hasInfix "stable" rustToolchainText))
      "rust-toolchain.toml must exist at the repo root with a stable channel so the POSIX devShell resolves to a pinned toolchain";

  # Verify that shell.nix sets LIBRARY_PATH to the Nix libiconv path on Darwin
  # so that rustup-managed cargo can link C-dependent crates (e.g. openssl-sys)
  # outside a devShell without hitting "ld: library not found for -liconv".
  # The Darwin guard ensures the variable is only set on macOS (Linux uses glibc).
  test_posix_shell_darwin_libiconv_library_path =
    assert'
      (
        (lib.hasInfix "LIBRARY_PATH" posixShellText)
        && (lib.hasInfix "libiconv" posixShellText)
        && (lib.hasInfix "isDarwin" posixShellText)
      )
      "shell.nix must set LIBRARY_PATH to the Nix libiconv path on Darwin for rustup-managed cargo builds outside a devShell";

  # Verify that __nucleus_run_managed_dev_tool in shell.nix contains the
  # rust-toolchain.toml pass-through check for cargo/rustc outside a direnv
  # context, scoped to cargo and rustc only.
  test_posix_shell_rust_toolchain_toml_check =
    assert'
      (
        (lib.hasInfix "rust-toolchain.toml" posixShellText) && (lib.hasInfix "cargo|rustc)" posixShellText)
      )
      "shell.nix __nucleus_run_managed_dev_tool must check for rust-toolchain.toml scoped to cargo/rustc";

  # Verify that Invoke-NucleusManagedDevTool in pwsh.nix contains the
  # rust-toolchain.toml pass-through check for cargo/rustc.
  test_posix_pwsh_rust_toolchain_toml_check = assert' (
    (lib.hasInfix "rust-toolchain.toml" posixPwshText) && (lib.hasInfix "''cargo''" posixPwshText)
  ) "pwsh.nix Invoke-NucleusManagedDevTool must check for rust-toolchain.toml scoped to cargo/rustc";

  # Verify that Invoke-NucleusManagedDevTool in Sync-ShellProfile.ps1 contains the
  # rust-toolchain.toml pass-through check for cargo/rustc on Windows.
  test_windows_shell_rust_toolchain_toml_check =
    assert'
      (
        (lib.hasInfix "rust-toolchain.toml" windowsShellProfileText)
        && (lib.hasInfix "''cargo''" windowsShellProfileText)
      )
      "Sync-ShellProfile.ps1 Invoke-NucleusManagedDevTool must check for rust-toolchain.toml scoped to cargo/rustc";

  # Verify that pkgs.nickel (CLI) and pkgs.nls (Nickel Language Server) are both
  # declared in core.nix baseSharedPackages so that .ncl tooling works on POSIX
  # hosts.  Windows installs nls via cargo-binstall (nickel-lang-lsp crate).
  test_core_nickel_lsp_in_shared_packages =
    assert' ((lib.hasInfix "pkgs.nickel" coreNixText) && (lib.hasInfix "pkgs.nls" coreNixText))
      "core.nix must include pkgs.nickel and pkgs.nls in baseSharedPackages for Nickel language support";

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
    # Verify test about removed libiconv in shell fallback.
    test_posix_shell_no_libiconv_fallback
    # Verify POSIX now uses pkgs.rustup (not pkgs.cargo).
    test_posix_uses_rustup_not_cargo_nix
    # Verify initRustup sets default none on POSIX.
    test_posix_init_rustup_sets_default_none
    test_windows_rustup_sets_default_stable
    test_posix_cargo_prunes_both_install_and_binstall
    test_windows_cargo_prunes_both_install_and_binstall
    test_uv_prune_parsing_and_validation_parity
    test_posix_devshell_uses_rust_overlay
    test_rust_toolchain_toml_exists_and_is_stable
    test_posix_shell_darwin_libiconv_library_path
    test_posix_shell_rust_toolchain_toml_check
    test_posix_pwsh_rust_toolchain_toml_check
    test_windows_shell_rust_toolchain_toml_check
    test_core_nickel_lsp_in_shared_packages
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} managed fallback tooling tests passed";
}
