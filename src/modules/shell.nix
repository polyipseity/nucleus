# Interactive shell configuration shared across all managed hosts.
#
# History exclusion features enabled here:
#   - HIST_IGNORE_SPACE: exclude commands starting with a space
#   - HIST_IGNORE_DUPS:  exclude consecutive duplicate commands
#
# When adding a new shell (bash, fish, nushell, etc.), enable the equivalent:
#   - bash:   HISTCONTROL=ignorespace:ignoredups
#   - fish:   fish_history ignore-space (or custom function)
#   - nu:     $env.config.shell_integration.history.exclude_patterns or similar
#   - cmd.exe: no equivalent — cannot be implemented
{
  config,
  lib,
  pkgs,
  username,
  nucleusApps,
  users ? null,
  ...
}:
let
  # Dedicated alias/env fragments keep list-like attrsets isolated so sort order
  # can be audited without scanning unrelated shell options.
  shellAliases = import ./shell/aliases.nix { };
  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };
  envVarsHelpers = import ./lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };

  # Single source of truth for AI agent session detection.  Shared with
  # pwsh.nix and Sync-ShellProfile.ps1 (Windows).
  agentEnv = import ./agent-env-vars.nix;

  # All env vars are sourced from the centralized catalog.
  mergedSessionVariables = envVarsHelpers.allVars;

  # Keep iCloud exclusion names and managed root paths in one declarative source
  # (users.json) so activation-time recursive marking and interactive shell hooks
  # converge on the same directory-name and managed-root policy.
  # Only Mobile Documents subpaths are valid managed roots here: the ignore xattr
  # is a native iCloud File Provider mechanism and must not be applied to legacy
  # convenience aliases like ~/Downloads/iCloud or ~/clouds/iCloud.
  _iCloudCfg =
    let
      allUsers = builtins.fromJSON (builtins.readFile ./users.json);
      effectiveUsers = if users != null then users else allUsers;
      currentUser = config.home.username;
      perUser =
        if
          builtins.hasAttr currentUser effectiveUsers
          && builtins.hasAttr "iCloudExclusions" effectiveUsers.${currentUser}
        then
          effectiveUsers.${currentUser}.iCloudExclusions
        else
          { };
      normalizeRoot = root: lib.removeSuffix "/." root;
      sanitizedManagedRoots =
        let
          candidateRoots = map normalizeRoot (perUser.managedRoots or [ ]);
          mobileDocumentsRoots = builtins.filter (
            root: root != "Library/Mobile Documents" && lib.hasPrefix "Library/Mobile Documents/" root
          ) candidateRoots;
        in
        if mobileDocumentsRoots != [ ] then
          mobileDocumentsRoots
        else
          [ "Library/Mobile Documents/com~apple~CloudDocs" ];
    in
    {
      excludedDirNames = perUser.excludedDirNames or [ ];
      managedRoots = sanitizedManagedRoots;
    };

  iCloudExcludedDirNames = _iCloudCfg.excludedDirNames;
  iCloudManagedRoots = _iCloudCfg.managedRoots;

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

in
{
  home.packages = builtins.attrValues nucleusApps;

  # direnv: automatically loads/unloads per-directory environments.
  # nix-direnv: caches nix-shell/flake devShells so re-entering a directory
  # does not trigger a full Nix evaluation each time.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # zoxide: a faster 'cd' that learns frequently used directories.
  # Integrates with zsh so 'z <query>' works in interactive sessions.
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    autosuggestion.enable = true; # inline history suggestions
    enable = true;
    enableCompletion = true; # tab completion via compinit
    shellAliases = shellAliases;
    syntaxHighlighting.enable = true; # command colouring (valid = green, etc.)

    # -----------------------------------------------------------------------
    # initContent: pay-respects shell integration + system-wide Python ban
    # -----------------------------------------------------------------------
    # pay-respects is initialised here rather than via a shell alias because
    # `eval "$(pay-respects zsh --alias)"` creates a zsh FUNCTION named `f`
    # that captures shell history and auto-executes the corrected command via
    # eval.  A plain alias (aliases.nix) would shadow the function — aliases
    # expand before functions in zsh — leaving `f` as a bare binary invocation
    # that neither executes the fix nor records it in history.
    # The build-tool ban wrappers follow; they must remain as functions (not aliases)
    # so they can emit multi-line guidance via heredoc and pass through when in a
    # devShell (DIRENV_DIR set) or via the managed default toolchain.
    initContent =
      builtins.replaceStrings
        [
          "__AGENT_ENV_VAR_CHECKS__"
          "__AGENT_DEVIN_PATH__"
          "__DEFAULT_DEV_TOOLS_PATH__"
          "__MACOS_ICLOUD_HOOKS__"
        ]
        [
          (lib.concatStringsSep "\n" (
            map (v: "  [[ -n \"\${${v}:-}\" ]] && return 0") agentEnv.agentEnvVarNames
          ))
          agentEnv.devinPosixPath
          "${managedPaths.defaultDevTools}"
          (lib.optionalString pkgs.stdenv.isDarwin (
            builtins.replaceStrings
              [ "__ICLOUD_EXCLUDED_NAMES__" "__ICLOUD_MANAGED_ROOTS__" ]
              [
                (lib.concatStringsSep " " (map lib.escapeShellArg iCloudExcludedDirNames))
                (lib.concatStringsSep " " (map lib.escapeShellArg iCloudManagedRoots))
              ]
              (builtins.readFile ../scripts/hosts/MacBook/macos-install-icloud-hooks.zsh)
          ))
        ]
        (builtins.readFile ../scripts/shell/init.zsh);
  };

  # User-scope package manager bin directories from the centralized catalog.
  # home.sessionPath writes to ~/.zshenv (via the HM session-vars mechanism)
  # which is sourced before ~/.zshrc (where the direnv hook lives), so these
  # entries are always part of the "original" PATH state that direnv saves and
  # restores — fixing the reliability issue of .zshrc-based PATH guards that
  # only run once at startup.
  # Sources: see pathComponents in src/modules/lib/managed-paths.nix.
  #   Prepends:    (before system default PATH)
  #   Appends:     bun install -g   → ~/.bun/bin   (BUN_INSTALL_BIN default)
  #                cargo-binstall   → ~/.cargo/bin  (CARGO_HOME/bin default)
  #                uv tool install  → ~/.local/bin  (XDG_BIN_HOME default)
  # Sole declaration site for home.sessionPath and home.sessionVariables.
  # No other file sets these — all env vars flow through the centralized
  # catalog in src/modules/lib/env-catalog.nix.
  home.sessionPath =
    (builtins.map (p: "${config.home.homeDirectory}/${p}") managedPaths.pathComponents.prepend)
    ++ (builtins.map (p: "${config.home.homeDirectory}/${p}") managedPaths.pathComponents.append);

  home.sessionVariables = mergedSessionVariables;

  # Global bun configuration: set a 5-day minimum release age for all package
  # installs (bun install -g, bun add, etc.). Bun reads bunfig.toml from $HOME
  # by default.
  # Source: https://bun.sh/docs/runtime/bunfig#install
  # Global bun configuration: set a 5-day minimum release age for all package
  # installs (bun install -g, bun add, etc.) and enable exact version pinning
  # in package.json (no caret ranges). Bun reads bunfig.toml from $HOME by default.
  # Source: https://bun.sh/docs/runtime/bunfig#install
  home.file.".bunfig.toml" = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/bun/bunfig.toml";
  };

  # Global Cargo configuration: per-platform linker selection.
  # Cargo evaluates cfg(target_os = "...") against the host build target at
  # config-load time — non-matching sections are silently ignored.
  #
  #   Linux   → mold via clang -fuse-ld=mold (fastest ELF linker)
  #   macOS   → native Apple ld64 via cc     (system default, explicit for clarity)
  #   Windows → rust-lld bundled with Rust    (zero-install, lld-link)
  home.file.".cargo/config.toml" = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/cargo/config.toml";
  };

  # Global nextest configuration: test runner UI settings.
  home.file.".config/nextest/config.toml" = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/nextest/config.toml";
  };

  # ---------------------------------------------------------------------------
  # Direnv: cross-platform base config + host-specific lib overrides
  # ---------------------------------------------------------------------------
  # The base direnvrc is cross-platform content deployed on all hosts. The apple-sdk
  # _nix() override has been moved to a lib/ file (auto-sourced by direnv before
  # direnvrc) so that Windows can deploy only the base config without dead code.
  #
  # apple-sdk's nix-support/setup-hook exports DEVELOPER_DIR, SDKROOT, and
  # NIX_APPLE_SDK_VERSION during nix print-dev-env evaluation.  These vars enter
  # direnv's managed environment set via the profile.rc that nix-direnv caches.
  # When you leave a direnv-managed directory, direnv strips all managed vars,
  # breaking xcrun until the next login shell re-sources hm-session-vars.
  #
  # The lib/apple-sdk-override.sh _nix() override filters those three variables
  # from the print-dev-env stdout before nix-direnv caches them.  They never enter
  # the managed set, so they survive directory transitions.
  #
  # direnv auto-sources ~/.config/direnv/lib/*.sh before ~/.config/direnv/direnvrc
  # and before the .envrc.  Since nix-direnv defines _nix in lib/hm-nix-direnv.sh,
  # our override in lib/ takes effect before the .envrc calls use_flake.
  # The _nix_direnv_nix variable is set by nix-direnv's _nix_direnv_preflight()
  # at the start of use_flake, so referencing it from the override is safe.
  home.file.".config/direnv/direnvrc" = {
    # check-suppress:config-method: method 1 (writable symlink) -- cross-platform base config.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/direnv/direnvrc";
  };

  # Host-specific apple-sdk _nix() override, auto-sourced by direnv before direnvrc.
  home.file.".config/direnv/lib/apple-sdk-override.sh" = {
    # check-suppress:config-method: method 1 (writable symlink) -- POSIX-only; Windows deploys only the base config.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/direnv/lib/apple-sdk-override.sh";
  };

  # Global uv configuration: exact pinning and supply-chain hardening.
  # uv reads uv.toml from $XDG_CONFIG_HOME/uv/uv.toml (~/.config/uv/uv.toml).
  # Source: https://docs.astral.sh/uv/reference/settings/#add-bounds
  # Source: https://docs.astral.sh/uv/reference/settings/#exclude-newer
  home.file."${config.xdg.configHome}/uv/uv.toml" = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/uv/uv.toml";
  };

  # ---------------------------------------------------------------------------
  # install-zsh-completions
  # Idempotently generates zsh completion files for CLI tools whose Nix packages
  # do not auto-bundle them into fpath, writing into the writable user-local
  # completion directory created in initContent.
  #
  # For each tool with a completion subcommand (bat, gh, uv, etc.), this step:
  #   * Probes the tool binary directly from the Nix store (no PATH dependency).
  #   * Skips regeneration if the completion file exists and is newer than the
  #     tool binary (mtime freshness check).
  #   * Fails gracefully if a completion subcommand exits non-zero (soft-fail).
  #
  # Why after install-cargo-binstall-packages: all Nix and non-Nix package managers
  # (bun, uv, cargo-binstall) have converged by that point, so every tool binary
  # that could provide completions is present before we try to generate them.
  # ---------------------------------------------------------------------------

  home.activation = {
    install-zsh-completions = lib.hm.dag.entryAfter [ "install-cargo-binstall-packages" ] ''
      "${activationBundle}/src/scripts/shell/install-zsh-completions.sh" \
        "${pkgs.bat}/bin/bat" \
        "${pkgs.bun}/bin/bun" \
        "${pkgs.fd}/bin/fd" \
        "${pkgs.gh}/bin/gh" \
        "${pkgs.opencode}/bin/opencode" \
        "${pkgs.ruff}/bin/ruff" \
        "${pkgs.rustup}/bin/rustup" \
        "${pkgs.typst}/bin/typst" \
        "${pkgs.uv}/bin/uv" \
        "${./completions/zsh}"
    '';
  };
}
