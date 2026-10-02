# Home Manager entrypoint shared by all three host types.
{
  config,
  lib,
  pkgs,
  repoRoot,
  username,
  users ? null,
  managedUsername ? null,
  managedUser ? null,
  hostName,
  ...
}:
let
  # managedUsername/managedUser are injected by mkHomeManagerUsers for
  # multi-user host evaluations; username is the standalone fallback.
  effectiveUsername = if managedUsername != null then managedUsername else username;

  effectiveUser =
    if managedUser != null then
      managedUser
    else if users != null && builtins.hasAttr effectiveUsername users then
      users.${effectiveUsername}
    else
      { };

  resolvedHomeDirectory =
    if effectiveUser ? homeDirectory then
      effectiveUser.homeDirectory
    else if hostName == "MacBook" then
      "/Users/${effectiveUsername}"
    else
      "/home/${effectiveUsername}";

  # Matches the path derive_repo_root() computes at runtime.
  nucleusUserRoot =
    if hostName == "MacBook" then
      "${resolvedHomeDirectory}/Library/Application Support/nucleus"
    else
      "${resolvedHomeDirectory}/.local/share/nucleus";

  passwordStoreDir =
    if effectiveUser ? passwordStore && effectiveUser.passwordStore ? path then
      builtins.replaceStrings [ "~" ] [ resolvedHomeDirectory ] effectiveUser.passwordStore.path
    else
      "${resolvedHomeDirectory}/.password-store";

  loggingPaths = import ./lib/logging-paths.nix { inherit pkgs hostName; };

  overlay = (import ./lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot hostName;
  };

  selectUserAppConfigFile = configName: relativePath: overlay.selectFile configName relativePath;

  # check-suppress:config-method: method 3 (merge) -- qtpass.nix returns declarative merged settings applied via platform-native stores (macOS defaults, Linux INI); imported module, not a deployed file
  qtpassModule = import ./configs/qtpass {
    inherit
      config
      lib
      pkgs
      passwordStoreDir
      ;
    qtPassDefaultSettings = builtins.fromJSON (
      builtins.readFile (selectUserAppConfigFile "qtpass" "qtpass.json")
    );
  };

  # check-suppress:config-method: method 3 (merge) -- LibreOffice owns registrymodifications.xcu and
  # overwrites it on exit. A symlink would be replaced. Merge injects managed
  # entries while preserving user-configured settings outside managed keys.
  libreOfficeModule = import ./configs/libreoffice {
    inherit lib;
    libreOfficeDefaultSettings = builtins.fromJSON (
      builtins.readFile (selectUserAppConfigFile "libreoffice" "libreoffice.json")
    );
  };

  # WHY: nativeMenus and checkSlowStartup are not configured: the first is stored
  # per-vault in appearance.json, the second is localStorage-backed. Both need the
  # vault path, which is app-owned state that changes at runtime.
  # check-suppress:config-method: method 3 (merge) -- see the activation entry below for full rationale.
  obsidianManagedSettings = builtins.fromJSON (
    builtins.readFile (selectUserAppConfigFile "obsidian" "obsidian.json")
  );
  obsidianManagedSettingsJson = builtins.toJSON obsidianManagedSettings;

  # WHY: Steam integration fields are pre-populated because autodetect only runs
  # on empty fields and can silently disable integration when workshop path
  # validation fails.
  # check-suppress:config-method: method 3 (merge) -- cannot use Method 1 (symlink) because RimSort owns
  # settings.json and writes theme, sorting, and window state into it.
  # A symlink would let those app-owned writes reach the repo file,
  # mixing managed settings with runtime state that does not belong
  # in the repo.  Merge preserves both managed and app-owned keys.
  rimsortManagedSettings = builtins.fromJSON (
    builtins.readFile (selectUserAppConfigFile "rimsort" "rimsort.json")
  );
  rimsortHostSettings = builtins.fromJSON (
    builtins.readFile (overlay.selectSource "rimsort" "rimsort.json")
  );
  rimsortManagedSettingsJson = builtins.toJSON (
    lib.recursiveUpdate rimsortManagedSettings rimsortHostSettings
  );

  # Each entry is { path, writable ? false }. `writable = false` (default) hardens
  # the symlink immutable (uchg on macOS, the only platform where a user-scope
  # activation can set the flag); `writable = true` stays managed but never
  # immutable, so an app can write the active config back through it. No check
  # step enforces the pairing, so the invariant lives here.
  managedSymlinkPaths = [
    { path = "${resolvedHomeDirectory}/iCloud"; }
    {
      path = "${resolvedHomeDirectory}/.config/camilladsp/configs";
      writable = true;
    }
    { path = "${resolvedHomeDirectory}/.config/camillagui-backend/config.yml"; }
    {
      path = "${resolvedHomeDirectory}/.config/discord-music-rpc/config.yaml";
      writable = true;
    }
    { path = "${resolvedHomeDirectory}/.config/starship.toml"; }
    { path = "${resolvedHomeDirectory}/Library/Application Support/iTerm2/DynamicProfiles"; }
    {
      # check-suppress:config-method: method 1 (writable symlink) -- srt settings are user-overridable via the standard overlay pattern.
      path = "${resolvedHomeDirectory}/.srt-settings.json";
      writable = true;
    }
    # LiteLLM config and handler symlinks, editable in the repo and picked up on service restart.
    {
      path = "${nucleusUserRoot}/litellm-config.yml";
      writable = true;
    }
    {
      path = "${nucleusUserRoot}/cline_handler.py";
      writable = true;
    }
    {
      path = "${nucleusUserRoot}/logging_config.json";
      writable = true;
    }
    {
      path = "${nucleusUserRoot}/logging_formatter.py";
      writable = true;
    }
  ];
  managedSymlinkPathsJson = builtins.toJSON managedSymlinkPaths;

  # Generated here rather than restated inside check step 13, whose hand-maintained
  # array had already drifted from the deployed set. The VS Code channel directories
  # cannot be reused verbatim from editors.nix, which spells $HOME literally.
  method1ManifestPaths =
    map (entry: entry.path) managedSymlinkPaths
    ++ [
      "${resolvedHomeDirectory}/.agents"
      "${resolvedHomeDirectory}/.config/opencode"
      "${resolvedHomeDirectory}/.cursor"
      "${resolvedHomeDirectory}/.pi/agent/extensions"
      "${resolvedHomeDirectory}/.pi/agent/settings.json"
      "${resolvedHomeDirectory}/data"
      nucleusUserRoot
    ]
    ++ (
      if pkgs.stdenv.hostPlatform.isDarwin then
        [
          "${resolvedHomeDirectory}/Library/Application Support/Code/User"
          "${resolvedHomeDirectory}/Library/Application Support/Code - Insiders/User"
        ]
      else
        [
          "${resolvedHomeDirectory}/.config/Code/User"
          "${resolvedHomeDirectory}/.config/Code - Insiders/User"
        ]
    );

  # check-suppress:config-method: method 3 (merge) -- Picard INI defaults are merged with user overrides.
  picardDefaultsIniText = builtins.readFile (selectUserAppConfigFile "picard" "Picard.ini");

  dotfilesRoot = ../dotfiles;

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  options.nucleus.rclone = {
    configPassEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether a managed rclone config passphrase secret exists for this user. Set to true by secrets.nix when src/secrets/users/<username>.yml is present and contains the rclone_config_pass key.";
    };
    configPassSecretPath = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Absolute path where sops-nix materializes the rclone config passphrase secret. Non-empty only when configPassEnabled is true.";
    };
  };

  imports = [
    ./lib/gc-options.nix
    ./lib/data-directory.nix
    ./agents.nix
    ./ai.nix
    ./cloud-drives.nix
    ./core.nix
    ./cursor.nix
    ./symlinks.nix
    ./dev-repos.nix
    ./editors.nix
    ./ext-discord-music-rpc.nix
    ./fonts.nix
    ./git.nix
    ./hermes-agent.nix
    ../platforms/NixOS/modules
    ./posix/logging.nix
    ../platforms/macOS/modules
    ./pwsh.nix
    ./secrets.nix
    ./shell
    ./shell
    ./terminal-activations.nix
    ./vagrant.nix
    ./voice-transcription.nix
    ./wallpapers.nix
  ];

  config = {
    home = {
      username = effectiveUsername;
      homeDirectory = lib.mkForce resolvedHomeDirectory;
      # Changing this after initial activation requires a deliberate migration.
      stateVersion = "24.11";
    };

    # darwin-rebuild inherits the Nix build directory as CWD, and activation can
    # delete it, so move to a safe path first.
    home.activation.ensure-safe-cwd = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      cd /
    '';

    # pass cannot encrypt or decrypt entries without .gpg-id, so init once with
    # the primary GPG key.
    #
    # WHY: managed-gpg-keys tracks imported keys by fingerprint; the primary RSA
    # key (978C2F10BDD68D5A7E2B12FA5E029A4348667405) is the canonical signing
    # key with ultimate ownertrust.  The PQC subkey (F4509882...) is for SOPS
    # encryption only and cannot be used by pass.
    home.activation.init-pass-store = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -f "${passwordStoreDir}/.gpg-id" ]; then
        "${pkgs.pass}/bin/pass" init "978C2F10BDD68D5A7E2B12FA5E029A4348667405" \
          --path "${passwordStoreDir}" 2>/dev/null \
          || true  # check-suppress:suppression_doc: pass init may fail if GPG agent is unavailable during non-interactive activation; store initializes on first use
      fi
    '';

    # QtPass persists its own settings (macOS defaults domain, Linux QSettings INI),
    # which can override PASSWORD_STORE_DIR and GUI behavior outside the shell.
    # check-suppress:config-method: method 3 (merge) -- cannot use Method 1 (symlink) because QtPass manages
    # its own UI preferences via QSettings (macOS: defaults, Linux: INI,
    # Windows: registry). A symlink does not apply to these platform-native
    # stores. Merge writes the managed defaults into each store while
    # preserving any user-configured settings outside managed keys.
    home.activation.merge-qtpass-ini = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/configs/merge-qtpass-ini.sh" \
        "${pkgs.gawk}/bin/awk" \
        ${lib.escapeShellArg qtpassModule.qtPassDarwinCommands} \
        ${lib.escapeShellArg qtpassModule.qtPassPrimaryIniCommands} \
        ${lib.escapeShellArg qtpassModule.qtPassSecondaryIniCommands}
    '';

    # The merge script takes the per-platform XCU path; Windows uses
    # Sync-LibreOfficeXcu.ps1.
    # check-suppress:config-method: method 3 (merge) -- cannot use Method 1 (symlink) because
    # LibreOffice owns registrymodifications.xcu and overwrites it on exit.
    # Merge applies managed metadata-stripping defaults while preserving
    # any user-configured settings outside managed keys.
    home.activation.merge-libreoffice-xcu = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/configs/merge-libreoffice-xcu.sh" \
        "${pkgs.python3}/bin/python3" \
        "${
          if pkgs.stdenv.hostPlatform.isDarwin then
            libreOfficeModule.libreOfficeDarwinXcuPath
          else
            libreOfficeModule.libreOfficeLinuxXcuPath
        }" \
        ${libreOfficeModule.libreOfficeMergeArgs}
    '';

    # check-suppress:config-method: method 3 (merge) -- cannot use Method 1 (symlink) because Picard manages
    # its INI through UI preferences (window state, plugin tokens, user
    # settings that should persist across applies). A symlink would let app
    # writes reach the repo file. Merge applies managed defaults while
    # preserving all app-owned keys and sections.
    home.activation.merge-picard-ini = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/configs/merge-picard-ini.sh" \
        "${pkgs.gawk}/bin/awk" \
        ${lib.escapeShellArg picardDefaultsIniText} \
        ""
    '';

    # check-suppress:config-method: method 3 (merge) -- cannot use Method 1 (symlink) because Obsidian owns
    # obsidian.json and writes vault metadata (vault paths, window state) into
    # it. A symlink would let those app-owned writes reach the repo file,
    # mixing managed settings with runtime state that does not belong in the
    # repo. Merge preserves both managed and app-owned keys.
    home.activation.merge-obsidian-json = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/configs/merge-obsidian-json.sh" \
        "${pkgs.python3}/bin/python3" \
        ${lib.escapeShellArg obsidianManagedSettingsJson}
    '';

    # check-suppress:config-method: method 3 (merge) -- cannot use Method 1 (symlink) because RimSort owns
    # settings.json and writes theme, sorting, and window state into it.
    # A symlink would let those app-owned writes reach the repo file,
    # mixing managed settings with runtime state that does not belong
    # in the repo.  Merge preserves both managed and app-owned keys.
    home.activation.merge-rimsort-json = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/configs/merge-rimsort-json.sh" \
        "${pkgs.python3}/bin/python3" \
        ${lib.escapeShellArg rimsortManagedSettingsJson}
    '';

    # macOS links the store binary, NixOS the steam-run wrapper.
    home.activation.provision-steamcmd = lib.hm.dag.entryAfter [ "merge-rimsort-json" ] ''
      "${activationBundle}/src/scripts/configs/provision-steamcmd.sh" \
        "${pkgs.python3}/bin/python3" \
        "${pkgs.steamcmd}" \
        ${lib.escapeShellArg rimsortManagedSettingsJson}
    '';

    # Protect out-of-store symlinks (mkOutOfStoreSymlink) against accidental
    # deletion between rebuilds.
    home.activation.unprotect-out-of-store-symlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/manage-out-of-store-symlinks.sh" "unprotect" "home.nix" '${managedSymlinkPathsJson}' "${pkgs.jq}/bin/jq"
    '';

    home.activation.protect-out-of-store-symlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/manage-out-of-store-symlinks.sh" "protect" "home.nix" '${managedSymlinkPathsJson}' "${pkgs.jq}/bin/jq"
    '';

    # Runs before protect-out-of-store-symlinks so a writable link is hardened
    # if the entry is not marked writable.
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    home.activation.seed-camilladsp-configs = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.config/camilladsp/configs" \
        "src/modules/configs/camilladsp/configs/${hostName}" \
        "${hostName}"
    '';

    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    home.activation.seed-camillagui-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.config/camillagui-backend/config.yml" \
        "src/modules/configs/camillagui-backend/config-${hostName}.yml" \
        "${hostName}"
    '';

    # check-suppress:config-method: method 1 (writable symlink) -- srt settings are user-overridable via the standard overlay pattern.
    home.activation.seed-srt-settings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.srt-settings.json" \
        "${overlay.toRepoRelPath (overlay.selectFile "srt" "settings.json")}"
    '';

    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    home.activation.seed-litellm-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${nucleusUserRoot}/litellm-config.yml" \
        "src/modules/configs/litellm/config.yml"
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${nucleusUserRoot}/cline_handler.py" \
        "src/modules/configs/litellm/cline_handler.py"
      # check-suppress:config-method: method 1 (writable symlink) -- litellm logging config; part of seed-litellm-config activation block.
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${nucleusUserRoot}/logging_config.json" \
        "src/modules/configs/litellm/logging_config.json"
      # check-suppress:config-method: method 1 (writable symlink) -- litellm logging formatter; part of seed-litellm-config activation block.
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${nucleusUserRoot}/logging_formatter.py" \
        "src/modules/configs/litellm/logging_formatter.py"
    '';

    # Runs after every seeder: a missing path means the owning seeder did not
    # converge and the app would read a nonexistent config. Unprotect tolerates
    # absence because it runs before the seeders.
    home.activation.verify-managed-symlink-paths =
      lib.hm.dag.entryAfter
        [
          "seed-camilladsp-configs"
          "seed-camillagui-config"
          "seed-discord-music-rpc-config"
          "seed-iterm2-dynamic-profiles"
          "seed-litellm-config"
          "seed-srt-settings"
        ]
        ''
          "${activationBundle}/src/scripts/configs/manage-out-of-store-symlinks.sh" "verify" "home.nix" '${managedSymlinkPathsJson}' "${pkgs.jq}/bin/jq"
        '';

    # An activation artifact rather than a home.file entry, so the audited nucleus
    # root holds a plain file instead of a store symlink.
    home.activation.write-method1-symlink-manifest = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/configs/write-method1-symlink-manifest.sh" \
        "${nucleusUserRoot}/method1-symlink-manifest.txt" \
        '${builtins.toJSON method1ManifestPaths}' \
        "${pkgs.jq}/bin/jq"
    '';

    # Runs after linkGeneration so symlinks.json entries are not clobbered.
    home.activation.provision-data-directory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/configs/provision-data-directory.sh" \
        "${config.home.homeDirectory}" \
        ${lib.escapeShellArg (builtins.toJSON config.nucleus.dataDirectory.manifest)} \
        "${pkgs.jq}/bin/jq"
    '';

    # The launchd path option types require an absolute path and do not expand ~.
    nucleus.logging.logDir = lib.mkDefault (
      builtins.replaceStrings [ "~" ] [ config.home.homeDirectory ] loggingPaths.logDirTemplate
    );

    # Allow Home Manager to manage its own activation and generation GC.
    programs.home-manager.enable = true;

    # Each entry is guarded by pathExists so a fresh checkout without the
    # dotfiles subtree still evaluates.
    home.file = lib.mkMerge [
      (lib.optionalAttrs (builtins.pathExists (dotfilesRoot + "/.config")) {
        ".config".source = dotfilesRoot + "/.config";
      })
      (lib.optionalAttrs (builtins.pathExists (dotfilesRoot + "/.gitconfig")) {
        ".gitconfig".source = dotfilesRoot + "/.gitconfig";
      })
      (lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        "iCloud".source =
          config.lib.file.mkOutOfStoreSymlink "${resolvedHomeDirectory}/Library/Mobile Documents/com~apple~CloudDocs";
      })
    ];
  };
}
