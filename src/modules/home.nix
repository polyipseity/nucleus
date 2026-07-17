# Home Manager entrypoint shared by all three host types.
# Multi-user aware: uses effectiveUsername / managedUsername dynamically
# rather than hardcoding a username. Respects per-user config from the
# user registry.
{
  config,
  lib,
  pkgs,
  username,
  users ? null,
  managedUsername ? null,
  managedUser ? null,
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
    else if pkgs.stdenv.isDarwin then
      "/Users/${effectiveUsername}"
    else
      "/home/${effectiveUsername}";

  passwordStoreDir =
    if effectiveUser ? passwordStore && effectiveUser.passwordStore ? path then
      builtins.replaceStrings [ "~" ] [ resolvedHomeDirectory ] effectiveUser.passwordStore.path
    else
      "${resolvedHomeDirectory}/.password-store";

  # Shared per-user app override accessor used by JSON-backed and native-format
  # app configs.  Keeping the attr-path checks in one place avoids each app
  # re-implementing the same defensive merge logic.
  userAppSettings =
    appName:
    if
      builtins.hasAttr appName effectiveUser
      && builtins.isAttrs effectiveUser.${appName}
      && builtins.hasAttr "settings" effectiveUser.${appName}
      && builtins.isAttrs effectiveUser.${appName}.settings
    then
      effectiveUser.${appName}.settings
    else
      { };

  managedAppSettings = appName: defaults: defaults // (userAppSettings appName);

  qtpassModule = import ./configs/qtpass/qtpass.nix {
    inherit
      config
      lib
      pkgs
      passwordStoreDir
      userAppSettings
      ;
  };

  # Obsidian reads its global app settings directly from obsidian.json, but the
  # file also contains dynamic vault metadata written by the app itself. Load
  # the managed settings from a declarative config file so they are versioned
  # and merge them into the live file without clobbering vault data.
  #
  # WHY nativeMenus is not configured: nativeMenus is stored per-vault in
  # appearance.json (.obsidian/appearance.json), not in obsidian.json. We cannot
  # manage vault-specific files without reading the vault path from obsidian.json,
  # which is app-owned state that changes at runtime.
  #
  # WHY checkSlowStartup is not configured: checkSlowStartup is localStorage-backed
  # and vault-specific. It cannot be declaratively managed via obsidian.json.
  obsidianDefaultSettings = builtins.fromJSON (builtins.readFile ./configs/obsidian/obsidian.json);

  obsidianManagedSettings = managedAppSettings "obsidian" obsidianDefaultSettings;
  obsidianManagedSettingsJson = builtins.toJSON obsidianManagedSettings;

  # Picard baseline defaults are sourced from the canonical native INI file.
  # We apply these defaults with merge-overwrite semantics, then layer
  # user-specific [setting] overrides from users.json.
  picardDefaultsIniText = builtins.readFile ./configs/picard/Picard.ini;
  picardUserSettings = userAppSettings "picard";

  renderIniScalarValue =
    value:
    if builtins.isBool value then
      if value then "true" else "false"
    else if builtins.isInt value then
      toString value
    else
      value;

  renderPicardIniCommand =
    confVar: section: name: value:
    let
      renderedValue = renderIniScalarValue value;
      valueArg = lib.escapeShellArg renderedValue;
    in
    ''_upsert_ini_key "${confVar}" "${section}" "${name}" ${valueArg}'';

  picardOverrideCommands = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: renderPicardIniCommand "$_picard_conf" "setting" name value
    ) picardUserSettings
  );

  # Path to the checked-out dotfiles/ directory at the root of this repo.
  dotfilesRoot = ../dotfiles;
in
{
  options.nucleus.rclone = {
    configPassEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether a managed rclone config passphrase secret exists for this user. Set to true by secrets.nix when src/secrets/users-<username>.yml is present and contains the rclone_config_pass key.";
    };
    configPassSecretPath = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Absolute path where sops-nix materializes the rclone config passphrase secret. Non-empty only when configPassEnabled is true.";
    };
  };

  imports = [
    ./agent-host-shell.nix
    ./agents.nix
    ./ai
    ./cloud-drives.nix
    ./core.nix
    ./custom-provision-symlinks.nix
    ./dev-repos.nix
    ./editors.nix
    ./ext-discord-music-rpc.nix
    ./fonts.nix
    ./git.nix
    ./linux.nix
    ./logging.nix
    ./macos.nix
    ./pwsh.nix
    ./secrets.nix
    ./starship.nix
    ./shell.nix
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
    home.activation.changeCwdToHome = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
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
    # Method 3 (merge) — cannot use Method 1 (symlink) because QtPass manages
    # its own UI preferences via QSettings (macOS: defaults, Linux: INI,
    # Windows: registry). A symlink does not apply to these platform-native
    # stores. Merge writes the managed defaults into each store while
    # preserving any user-configured settings outside managed keys.
    home.activation."qtpass-merge-ini" = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export AWK_PATH="${pkgs.gawk}/bin/awk"
      ${builtins.readFile ../scripts/configs/qtpass-merge-ini.sh}

      case "$(uname -s)" in
        Darwin)
          ${qtpassModule.qtPassDarwinCommands}
          ;;
        Linux)
          # QtPass upstream commonly resolves to ~/.config/IJHack/QtPass.conf.
          _primary_conf="$HOME/.config/IJHack/QtPass.conf"
          # Some builds may resolve via organization-domain pathing.
          _secondary_conf="$HOME/.config/com.ijhack/QtPass.conf"

          ${qtpassModule.qtPassPrimaryIniCommands}
          if [ -f "$_secondary_conf" ]; then
            ${qtpassModule.qtPassSecondaryIniCommands}
          fi
          ;;
      esac
    '';

    # Picard reads native INI settings from ~/.config/MusicBrainz/Picard.ini
    # on macOS and Linux. Merge-overwrite defaults from the canonical
    # Picard.ini baseline file, then layer per-user [setting] overrides.
    # Always preserve unmanaged keys and sections.
    # Method 3 (merge) — cannot use Method 1 (symlink) because Picard manages
    # its INI through UI preferences (window state, plugin tokens, user
    # settings that should persist across applies). A symlink would let app
    # writes reach the repo file. Merge applies managed defaults while
    # preserving all app-owned keys and sections.
    home.activation."picard-merge-ini" = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export AWK_PATH="${pkgs.gawk}/bin/awk"
      export PICARD_DEFAULTS_INI=${lib.escapeShellArg picardDefaultsIniText}
      ${builtins.readFile ../scripts/configs/picard-merge-ini.sh}
      ${picardOverrideCommands}
    '';

    # Obsidian stores app-global settings in obsidian.json alongside dynamic
    # vault metadata.  Merge only the managed advanced-setting keys into that
    # file so the declarative defaults converge without clobbering vault lists
    # or other app-owned state.
    #
    # Method 3 (merge) — cannot use Method 1 (symlink) because Obsidian owns
    # obsidian.json and writes vault metadata (vault paths, window state) into
    # it. A symlink would let those app-owned writes reach the repo file,
    # mixing managed settings with runtime state that does not belong in the
    # repo. Merge preserves both managed and app-owned keys.
    home.activation."obsidian-merge-json" = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -eu

      case "$(uname -s)" in
        Darwin)
          _obsidian_settings_path="$HOME/Library/Application Support/obsidian/obsidian.json"
          ;;
        Linux)
          _obsidian_settings_path="''${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/obsidian.json"
          ;;
        *)
          exit 0
          ;;
      esac

      mkdir -p "$(dirname "$_obsidian_settings_path")"
      ${pkgs.python3}/bin/python3 -c '${builtins.readFile ../scripts/configs/obsidian-merge-json.py}' "$_obsidian_settings_path" ${lib.escapeShellArg obsidianManagedSettingsJson}
    '';

    # Protect out-of-store symlinks (mkOutOfStoreSymlink) against accidental
    # deletion between rebuilds.
    home.activation.unprotectOutOfStoreSymlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      ${builtins.readFile ../scripts/lib/symlink-hardening-lib.sh}
      _nucleus_unprotect_symlink "home.nix" "$HOME/iCloud"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/camilladsp/configs"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/camillagui-backend/config.yml"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/discord-music-rpc/config.yaml"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/starship.toml"
      _nucleus_unprotect_symlink "home.nix" "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
    '';

    home.activation.protectOutOfStoreSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      ${builtins.readFile ../scripts/lib/symlink-hardening-lib.sh}
      _nucleus_protect_symlink "home.nix" "$HOME/iCloud"
      _nucleus_protect_symlink "home.nix" "$HOME/.config/camilladsp/configs"
      _nucleus_protect_symlink "home.nix" "$HOME/.config/camillagui-backend/config.yml"
      _nucleus_protect_symlink "home.nix" "$HOME/.config/discord-music-rpc/config.yaml"
      _nucleus_protect_symlink "home.nix" "$HOME/.config/starship.toml"
      _nucleus_protect_symlink "home.nix" "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
    '';

    # Override the default logDir (which uses ~) with a proper absolute path.
    # The launchd StandardErrorPath/StandardOutPath option types require an
    # absolute path and do not expand ~.
    nucleus.logging.logDir = lib.mkDefault (
      if pkgs.stdenv.isDarwin then
        "${config.home.homeDirectory}/Library/Logs/nucleus"
      else
        "${config.home.homeDirectory}/.local/state/nucleus/log"
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
      (
        let
          configName = if pkgs.stdenv.isDarwin then "macos" else "linux";
        in
        {
          ".config/camilladsp/configs".source =
            config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/camilladsp/configs/${configName}";
          ".config/camillagui-backend/config.yml".source =
            config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/camillagui-backend/config-${configName}.yml";
        }
      )
      (lib.optionalAttrs pkgs.stdenv.isDarwin {
        # Keep iCloud Drive reachable from a short, stable path for all managed
        # macOS users so scripts and shell workflows avoid long spaced paths.
        "iCloud".source =
          config.lib.file.mkOutOfStoreSymlink "${resolvedHomeDirectory}/Library/Mobile Documents/com~apple~CloudDocs";
      })
    ];
  };
}
