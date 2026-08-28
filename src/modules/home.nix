# Home Manager entrypoint shared by all three host types.
# Multi-user aware: uses effectiveUsername / managedUsername dynamically
# rather than hardcoding a username. Respects per-user config from the
# user registry.
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
  # Determine the effective user context for this Home Manager evaluation.
  # managedUsername/managedUser are injected by mkHomeManagerUsers for
  # multi-user host evaluations; fallback to legacy args for standalone usage.
  effectiveUsername = if managedUsername != null then managedUsername else username;

  effectiveUser =
    if managedUser != null then
      managedUser
    else if users != null && builtins.hasAttr effectiveUsername users then
      users.${effectiveUsername}
    else
      { };

  # Derive the home directory from platform conventions. Keeping this local to
  # the module avoids relying on ad-hoc `_module.args` plumbed through every
  # call site.
  resolvedHomeDirectory =
    if effectiveUser ? homeDirectory then
      effectiveUser.homeDirectory
    else if hostName == "MacBook" then
      "/Users/${effectiveUsername}"
    else
      "/home/${effectiveUsername}";

  passwordStoreDir =
    if effectiveUser ? passwordStore && effectiveUser.passwordStore ? path then
      builtins.replaceStrings [ "~" ] [ resolvedHomeDirectory ] effectiveUser.passwordStore.path
    else
      "${resolvedHomeDirectory}/.password-store";

  loggingPaths = import ./lib/logging-paths.nix { inherit pkgs hostName; };

  overlay = (import ./lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  selectUserAppConfigFile = configName: relativePath: overlay.selectFile configName relativePath;

  # check-suppress:config-method: method 3 (merge) -- qtpass.nix returns declarative merged settings applied via platform-native stores (macOS defaults, Linux INI); imported module, not a deployed file
  qtpassModule = import ./configs/qtpass/qtpass.nix {
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

  # Obsidian reads its global app settings directly from obsidian.json, but the
  # file also contains dynamic vault metadata written by the app itself. Load
  # the managed settings from a declarative config file so they are versioned
  # and merge them into the live file without clobbering vault data.
  #
  # WHY: nativeMenus is not configured: nativeMenus is stored per-vault in
  # appearance.json (.obsidian/appearance.json), not in obsidian.json. We cannot
  # manage vault-specific files without reading the vault path from obsidian.json,
  # which is app-owned state that changes at runtime.
  #
  # WHY: checkSlowStartup is not configured: checkSlowStartup is localStorage-backed
  # and vault-specific. It cannot be declaratively managed via obsidian.json.
  # check-suppress:config-method: method 3 (merge) -- see the activation entry below for full rationale.
  obsidianManagedSettings = builtins.fromJSON (
    builtins.readFile (selectUserAppConfigFile "obsidian" "obsidian.json")
  );
  obsidianManagedSettingsJson = builtins.toJSON obsidianManagedSettings;

  # Out-of-store symlink paths protected across activation cycles.
  # Expanded from $HOME to resolvedHomeDirectory at eval time so the JSON
  # token carries absolute paths and no shell expansion is needed at runtime.
  # Each entry is { path, writable ? false }. `writable = false` (default) hardens
  # the symlink immutable (uchg/chattr +i) so it cannot be deleted or written
  # through; `writable = true` keeps it managed (still unprotect-before/re-protect-after)
  # but never immutable, so apps can write the active config back through it.
  # A `method 1 (writable symlink)` deployment MUST be `writable = true` — see
  # the config-method compliance check (step 14) which bans immutable Method 1 links.
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
  ];
  managedSymlinkPathsJson = builtins.toJSON managedSymlinkPaths;

  # Picard baseline defaults are sourced from the canonical native INI file.
  # We apply these defaults with merge-overwrite semantics.
  # check-suppress:config-method: method 3 (merge) -- Picard INI defaults are merged with user overrides.
  picardDefaultsIniText = builtins.readFile (selectUserAppConfigFile "picard" "Picard.ini");

  # Path to the checked-out dotfiles/ directory at the root of this repo.
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
    ./agents.nix
    ./ai
    ./camilladsp.nix
    ./cloud-drives.nix
    ./core.nix
    ./cursor.nix
    ./symlinks.nix
    ./dev-repos.nix
    ./editors.nix
    ./ext-discord-music-rpc.nix
    ./fonts.nix
    ./git.nix
    ../platforms/NixOS/modules
    ./logging.nix
    ../platforms/macOS/modules
    ./pwsh.nix
    ./secrets.nix
    ./starship.nix
    ./shell.nix
    ./terminal-activations.nix
    ./wallpapers.nix
  ];

  config = {
    home = {
      username = effectiveUsername;
      homeDirectory = lib.mkDefault resolvedHomeDirectory;
      # Pin the Home Manager state version; changing this after initial
      # activation requires a deliberate migration.
      stateVersion = "24.11";
    };

    # Change CWD to a safe location before any activation steps. The Nix build
    # directory that darwin-rebuild inherits as CWD can be deleted during
    # activation, causing harmless but noisy getcwd errors.
    home.activation.ensure-safe-cwd = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      cd /
    '';

    # QtPass keeps its own persisted settings store, which can override
    # PASSWORD_STORE_DIR and GUI behavior when launched outside the shell.
    #
    # - macOS: configure the com.ijhack.QtPass defaults domain.
    # - Linux: configure Qt's INI-backed settings file (QSettings).
    #
    # Keep both aligned with the per-user passwordStoreDir and the shared
    # screenshot-backed Settings + Template tab baseline, while still allowing
    # centralized per-user overrides from flake.nix.
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

    # Picard reads native INI settings from ~/.config/MusicBrainz/Picard.ini
    # on macOS and Linux. Merge-overwrite defaults from the canonical
    # Picard.ini baseline file, then layer per-user [setting] overrides.
    # Always preserve unmanaged keys and sections.
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

    # Obsidian stores app-global settings in obsidian.json alongside dynamic
    # vault metadata.  Merge only the managed advanced-setting keys into that
    # file so the declarative defaults converge without clobbering vault lists
    # or other app-owned state.
    #
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

    # Protect out-of-store symlinks (mkOutOfStoreSymlink) against accidental
    # deletion between rebuilds.
    home.activation.unprotect-out-of-store-symlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/manage-out-of-store-symlinks.sh" "unprotect" "home.nix" '${managedSymlinkPathsJson}' "${pkgs.jq}/bin/jq"
    '';

    home.activation.protect-out-of-store-symlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/manage-out-of-store-symlinks.sh" "protect" "home.nix" '${managedSymlinkPathsJson}' "${pkgs.jq}/bin/jq"
    '';

    # Method-1 (writable) symlink for the camilladsp config directory. Created at
    # activation time against the LIVE repo root so the GUI can write config.yml
    # back through to the repo (repo changes take effect without rebuild). The
    # writable/immutable decision is owned by managedSymlinkPaths; this entry must
    # run before protect-out-of-store-symlinks so the link is hardened if immutable.
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    home.activation.seed-camilladsp-configs = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.config/camilladsp/configs" \
        "src/modules/configs/camilladsp/configs/${hostName}" \
        "${hostName}"
    '';

    # Method-1 (writable) symlink for the camillagui-backend config file. Created at
    # activation time against the LIVE repo root so repo edits show without rebuild.
    # The GUI does not write this file, but it must still point at the live repo.
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    home.activation.seed-camillagui-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.config/camillagui-backend/config.yml" \
        "src/modules/configs/camillagui-backend/config-${hostName}.yml" \
        "${hostName}"
    '';

    # Override the default logDir (which uses ~) with a proper absolute path.
    # The launchd StandardErrorPath/StandardOutPath option types require an
    # absolute path and do not expand ~.
    nucleus.logging.logDir = lib.mkDefault (
      builtins.replaceStrings [ "~" ] [ config.home.homeDirectory ] loggingPaths.logDirTemplate
    );

    # Allow Home Manager to manage its own activation and generation GC.
    programs.home-manager.enable = true;

    # Declaratively symlink dotfile directories/files into the home directory.
    # Each entry is guarded by pathExists so a missing dotfiles subtree does not
    # cause an eval error on a fresh checkout.
    home.file = lib.mkMerge [
      (lib.optionalAttrs (builtins.pathExists (dotfilesRoot + "/.config")) {
        ".config".source = dotfilesRoot + "/.config";
      })
      (lib.optionalAttrs (builtins.pathExists (dotfilesRoot + "/.gitconfig")) {
        ".gitconfig".source = dotfilesRoot + "/.gitconfig";
      })
      (lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        # Keep iCloud Drive reachable from a short, stable path for all managed
        # macOS users so scripts and shell workflows avoid long spaced paths.
        "iCloud".source =
          config.lib.file.mkOutOfStoreSymlink "${resolvedHomeDirectory}/Library/Mobile Documents/com~apple~CloudDocs";
      })
    ];
  };
}
