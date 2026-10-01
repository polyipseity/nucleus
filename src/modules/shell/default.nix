# Interactive shell configuration shared across all managed hosts. The history
# exclusions (HIST_IGNORE_SPACE, HIST_IGNORE_DUPS) need per-shell equivalents
# when a new shell is added: bash HISTCONTROL=ignorespace:ignoredups, fish
# fish_history ignore-space, nu history.exclude_patterns. cmd.exe has none.
{
  config,
  lib,
  pkgs,
  repoRoot,
  username,
  managedUsername ? null,
  nucleusApps,
  users ? null,
  hostName,
  ...
}:
let
  effectiveUsername = if managedUsername != null then managedUsername else config.home.username;
  overlay = (import ../lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot hostName;
  };

  # Alias/env fragments stay isolated so sort order can be audited on its own.
  shellAliases = import ./aliases.nix { };
  managedPaths = import ../lib/managed-paths.nix { inherit pkgs; };
  envVarsHelpers = import ../lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      hostName
      ;
  };

  # AI agent session detection names, shared with pwsh.nix and Sync-ShellProfile.ps1.
  agentEnv = import ./agent-env-vars.nix;

  mergedSessionVariables = envVarsHelpers.allVars;

  # WHY: iCloud exclusion names and managed roots live in src/users/ so
  # activation and the interactive hooks share one policy. Only Mobile Documents
  # subpaths qualify, since the ignore xattr is a File Provider mechanism and
  # would break aliases like ~/Downloads/iCloud.
  _iCloudCfg =
    let
      currentUser = config.home.username;
      perUser =
        if
          users != null
          && builtins.hasAttr currentUser users
          && builtins.hasAttr "iCloudExclusions" users.${currentUser}
        then
          users.${currentUser}.iCloudExclusions
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

  activationBundle = pkgs.callPackage ../lib/script-tree.nix { };

in
{
  home.packages = builtins.attrValues (
    builtins.removeAttrs nucleusApps [ "nucleus-service-watchdog" ]
  );

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

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

    # pay-respects needs initContent rather than an alias: `eval "$(pay-respects
    # zsh --alias)"` defines a zsh FUNCTION, and an alias would expand first and
    # leave `f` as a bare binary call that neither fixes nor records the command.
    # The build-tool bans must also stay functions, so they can emit heredoc
    # guidance and pass through in a devShell.
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
          (lib.optionalString pkgs.stdenv.hostPlatform.isDarwin (
            builtins.replaceStrings
              [ "__ICLOUD_EXCLUDED_NAMES__" "__ICLOUD_MANAGED_ROOTS__" ]
              [
                (lib.concatStringsSep " " (map lib.escapeShellArg iCloudExcludedDirNames))
                (lib.concatStringsSep " " (map lib.escapeShellArg iCloudManagedRoots))
              ]
              (builtins.readFile ../../platforms/macOS/scripts/macos-install-icloud-hooks.zsh)
          ))
        ]
        (builtins.readFile ../../scripts/shell/init.zsh);
  };

  # WHY ~/.zshenv: direnv saves and restores the PATH it sees at shell start, so
  # PATH must be complete before ~/.zshrc. Sole declaration site for
  # home.sessionPath; every env var flows through the catalog in
  # src/modules/lib/env-secrets.nix. pathComponents live in managed-paths.nix.
  home.sessionPath =
    (builtins.map (p: "${config.home.homeDirectory}/${p}") managedPaths.pathComponents.prepend)
    ++ (builtins.map (p: "${config.home.homeDirectory}/${p}") managedPaths.pathComponents.append);

  home.sessionVariables = mergedSessionVariables;

  # 5-day minimum release age plus exact version pinning. Source:
  # https://bun.sh/docs/runtime/bunfig#install
  # Seeded against the LIVE repo root so repo edits apply without a rebuild.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-bunfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.bunfig.toml" \
      "${overlay.toRepoRelPath (overlay.selectFile "bun" "bunfig.toml")}" \
  '';

  # Cargo matches cfg(target_os) against the host target, so non-matching
  # sections are silently ignored: Linux uses mold, macOS native ld64, Windows
  # the bundled rust-lld.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-cargo-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.cargo/config.toml" \
      "${overlay.toRepoRelPath (overlay.selectFile "cargo" "config.toml")}" \
  '';

  # nextest runner UI settings.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-nextest-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/nextest/config.toml" \
      "${overlay.toRepoRelPath (overlay.selectFile "nextest" "config.toml")}" \
  '';

  # WHY the lib/ override: apple-sdk's setup-hook exports DEVELOPER_DIR, SDKROOT
  # and NIX_APPLE_SDK_VERSION into the set direnv manages and strips on leave,
  # breaking xcrun. Filtering them out of print-dev-env keeps them out of that
  # set. direnv sources lib/*.sh before direnvrc, so the override runs before
  # use_flake sets _nix_direnv_nix.
  # check-suppress:config-method: method 1 (writable symlink) -- cross-platform base config.
  home.activation.seed-direnvrc = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/direnv/direnvrc" \
      "${overlay.toRepoRelPath (overlay.selectFile "direnv" "direnvrc")}" \
  '';

  # WHY POSIX only: Windows deploys the base direnvrc without this override.
  # check-suppress:config-method: method 1 (writable symlink) -- POSIX-only; Windows deploys only the base config.
  home.activation.seed-direnv-apple-sdk-override = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/direnv/lib/apple-sdk-override.sh" \
      "${overlay.toRepoRelPath (overlay.selectFile "direnv" "lib/apple-sdk-override.sh")}" \
  '';

  # Exact pinning and supply-chain hardening. Sources:
  # https://docs.astral.sh/uv/reference/settings/#add-bounds
  # https://docs.astral.sh/uv/reference/settings/#exclude-newer
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-uv-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/uv/uv.toml" \
      "${overlay.toRepoRelPath (overlay.selectFile "uv" "uv.toml")}" \
  '';

  # User-scoped `node` shim resolving to bun. ~/.local/bin is already on the
  # append PATH; init.zsh still blocks an interactive `node`.
  home.file.".local/bin/node" = {
    source = "${managedPaths.nodeShim}/bin/node";
  };

  # Probes each tool's Nix store binary, skips regeneration when the completion
  # file is newer than the binary, and soft-fails on a non-zero subcommand exit.
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
        "${../completions/zsh}"
    '';
  };
}
