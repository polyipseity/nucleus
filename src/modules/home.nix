# modules/home.nix — Home Manager entrypoint shared by all three host types.
#
# Imported by flake.nix once per host inside a home-manager.users.* block or a
# homeManagerConfiguration call.  Responsible for:
#   • resolving the platform-appropriate home directory path
#   • importing all shared feature modules
#   • symlinking dotfiles from the repo's dotfiles/ tree into the home directory
{
  config,
  lib,
  pkgs,
  username,
  users ? null,
  managedUsername ? null,
  managedUser ? null,
  hostManualFile ? null,
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

  # QtPass settings baseline (screenshot-verified): shared across all platforms
  # unless overridden by platform-specific or per-user settings.
  # Platform overrides: hideOnClose=false on macOS; user overrides from flake.nix.
  qtPassDefaultSettings = {
    addGPGId = true;
    alwaysOnTop = true;
    autoPull = false;
    autoPush = false;
    autoclearPanelSeconds = 5;
    autoclearSeconds = 10;
    avoidCapitals = false;
    avoidNumbers = false;
    clipBoardType = 2;
    displayAsIs = false;
    hideContent = false;
    hideOnClose = true;
    hidePassword = true;
    lessRandom = false;
    noLineWrapping = false;
    passTemplate = "login\nurl\ndescription\n";
    passwordCharsselection = 0;
    passwordLength = 15;
    startMinimized = false;
    templateAllFields = true;
    useAutoclear = true;
    useAutoclearPanel = true;
    useGit = true;
    useMonospace = true;
    useOtp = true;
    usePwgen = true;
    useQrencode = false;
    useSelection = false;
    useSymbols = true;
    useTemplate = true;
    useTrayIcon = true;
  };

  qtPassPlatformSettings = lib.optionalAttrs pkgs.stdenv.isDarwin {
    # macOS keeps Hide on close disabled, per the requested platform-specific
    # exception to the shared QtPass baseline.
    hideOnClose = false;
  };

  qtPassManagedSettings =
    (qtPassDefaultSettings // qtPassPlatformSettings // (userAppSettings "qtpass"))
    // {
      passStore = "${lib.removeSuffix "/" passwordStoreDir}/";
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
  obsidianDefaultSettings = builtins.fromJSON (builtins.readFile ./configs/obsidian.json);

  obsidianManagedSettings = managedAppSettings "obsidian" obsidianDefaultSettings;
  obsidianManagedSettingsJson = builtins.toJSON obsidianManagedSettings;

  renderQtPassValue =
    value:
    if builtins.isBool value then
      if value then "true" else "false"
    else if builtins.isInt value then
      toString value
    else
      value;

  renderQtPassDefaultsCommand =
    name: value:
    let
      renderedValue = renderQtPassValue value;
      valueArg = lib.escapeShellArg renderedValue;
      valueFlag =
        if builtins.isBool value then
          "-bool"
        else if builtins.isInt value then
          "-int"
        else
          "-string";
    in
    "/usr/bin/defaults write com.ijhack.QtPass ${name} ${valueFlag} ${valueArg}";

  renderQtPassIniCommand =
    confVar: name: value:
    let
      renderedValue = renderQtPassValue value;
      valueArg =
        if builtins.isString value then
          ''"$(_escape_qsettings_ini_string ${lib.escapeShellArg renderedValue})"''
        else
          lib.escapeShellArg renderedValue;
    in
    ''_update_qtpass_ini_value "${confVar}" "${name}" ${valueArg}'';

  qtPassDarwinCommands = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList renderQtPassDefaultsCommand qtPassManagedSettings
  );

  qtPassPrimaryIniCommands = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: renderQtPassIniCommand "$_primary_conf" name value
    ) qtPassManagedSettings
  );

  qtPassSecondaryIniCommands = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: renderQtPassIniCommand "$_secondary_conf" name value
    ) qtPassManagedSettings
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

  options.nucleus.hostManualFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Host-scoped MANUAL.md path (absolute or repo-relative) printed by OS-specific activation modules at the end of Home Manager activation.";
  };

  imports = [
    ./agents.nix
    ./ai
    ./cloud-drives.nix
    ./core.nix
    ./dev-repos.nix
    ./editors.nix
    ./fonts.nix
    ./git.nix
    ./linux.nix
    ./macos.nix
    ./pwsh.nix
    ./secrets.nix
    ./shell.nix
    ./wallpapers.nix
  ];

  config = {
    # Preserve call-site convenience for standalone Home Manager invocations
    # that pass hostManualFile via module arguments, while keeping the option
    # default path-free to avoid options.json derivation context warnings.
    nucleus.hostManualFile = lib.mkDefault hostManualFile;

    home = {
      username = effectiveUsername;
      homeDirectory = lib.mkDefault resolvedHomeDirectory;
      # Pin the Home Manager state version; changing this after initial
      # activation requires a deliberate migration.
      stateVersion = "24.11";
    };

    # Per-user password store routing for pass/QtPass/gopass.
    # - pass and QtPass respect PASSWORD_STORE_DIR directly.
    # - gopass also supports PASSWORD_STORE_DIR and explicit config overrides;
    #   set config override env keys so gopass always resolves this path.
    home.sessionVariables = {
      GOPASS_CONFIG_COUNT = "1";
      GOPASS_CONFIG_KEY_1 = "path";
      GOPASS_CONFIG_VALUE_1 = passwordStoreDir;
      PASSWORD_STORE_DIR = passwordStoreDir;
    };

    # QtPass keeps its own persisted settings store, which can override
    # PASSWORD_STORE_DIR and GUI behavior when launched outside the shell.
    #
    # - macOS: configure the com.ijhack.QtPass defaults domain.
    # - Linux: configure Qt's INI-backed settings file (QSettings).
    #
    # Keep both aligned with the per-user passwordStoreDir and the shared
    # screenshot-backed Settings + Template tab baseline, while still allowing
    # centralized per-user overrides from flake.nix.
    home.activation.configureQtPassSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            _escape_qsettings_ini_string() {
              printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e ':join' -e 'N' -e '$!b join' -e 's/\n/\\n/g'
            }

            _update_qtpass_ini_value() {
              _conf="$1"
              _key="$2"
              _value="$3"
              _conf_dir="$(dirname "$_conf")"
              mkdir -p "$_conf_dir"

              if [ -f "$_conf" ]; then
                _tmp="$(mktemp "$_conf.XXXXXX")"
                awk -v key="$_key" -v value="$_value" '
                  BEGIN { in_general = 0; wrote = 0 }
                  {
                    if ($0 ~ /^\[General\]$/) {
                      if (in_general && wrote == 0) {
                        print key "=" value
                        wrote = 1
                      }
                      in_general = 1
                      print
                      next
                    }

                    if ($0 ~ /^\[/ && $0 !~ /^\[General\]$/) {
                      if (in_general && wrote == 0) {
                        print key "=" value
                        wrote = 1
                      }
                      in_general = 0
                      print
                      next
                    }

                    if (in_general && $0 ~ ("^" key "=")) {
                      if (wrote == 0) {
                        print key "=" value
                        wrote = 1
                      }
                      next
                    }

                    print
                  }
                  END {
                    if (wrote == 0) {
                      if (in_general == 0) {
                        print "[General]"
                      }
                      print key "=" value
                    }
                  }
                ' "$_conf" > "$_tmp"
                mv "$_tmp" "$_conf"
              else
                cat > "$_conf" <<EOF
      [General]
      $_key=$_value
      EOF
              fi
            }

            case "$(uname -s)" in
              Darwin)
                ${qtPassDarwinCommands}
                ;;
              Linux)
                # QtPass upstream commonly resolves to ~/.config/IJHack/QtPass.conf.
                _primary_conf="$HOME/.config/IJHack/QtPass.conf"
                # Some builds may resolve via organization-domain pathing.
                _secondary_conf="$HOME/.config/com.ijhack/QtPass.conf"

                ${qtPassPrimaryIniCommands}
                if [ -f "$_secondary_conf" ]; then
                  ${qtPassSecondaryIniCommands}
                fi
                ;;
            esac
    '';

    # Obsidian stores app-global settings in obsidian.json alongside dynamic
    # vault metadata.  Merge only the managed advanced-setting keys into that
    # file so the declarative defaults converge without clobbering vault lists
    # or other app-owned state.
    home.activation.configureObsidianSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
            ${pkgs.python3}/bin/python3 - "$_obsidian_settings_path" ${lib.escapeShellArg obsidianManagedSettingsJson} <<'PY'
      import json
      import sys
      from pathlib import Path

      config_path = Path(sys.argv[1])
      managed = json.loads(sys.argv[2])

      if config_path.exists():
          raw = config_path.read_text(encoding="utf-8")
          existing = json.loads(raw) if raw.strip() else {}
      else:
          existing = {}

      if not isinstance(existing, dict):
          print(f"obsidian: expected top-level JSON object in {config_path}", file=sys.stderr)
          sys.exit(1)

      existing.update(managed)
      config_path.write_text(json.dumps(existing, separators=(",", ":")), encoding="utf-8")
      PY
    '';

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
      (lib.optionalAttrs pkgs.stdenv.isDarwin {
        # Keep iCloud Drive reachable from a short, stable path for all managed
        # macOS users so scripts and shell workflows avoid long spaced paths.
        "iCloud".source =
          config.lib.file.mkOutOfStoreSymlink "${resolvedHomeDirectory}/Library/Mobile Documents/com~apple~CloudDocs";
      })
    ];
  };
}
