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

  qtpassModule = import ./configs/qtpass.nix {
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
  obsidianDefaultSettings = builtins.fromJSON (builtins.readFile ./configs/obsidian.json);

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

    # Per-user password store routing for pass/QtPass/gopass.
    # - pass and QtPass respect PASSWORD_STORE_DIR directly.
    # - gopass also supports PASSWORD_STORE_DIR and explicit config overrides;
    #   set config override env keys so gopass always resolves this path.
    home.sessionVariables = {
      GOPASS_CONFIG_COUNT = "1";
      GOPASS_CONFIG_KEY_1 = "path";
      GOPASS_CONFIG_VALUE_1 = passwordStoreDir;
      PASSWORD_STORE_DIR = passwordStoreDir;
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      # Point out-of-store symlinks (e.g. CamillaDSP config) at the live repo
      # tree so activation scripts can wire them up without dry-run uncertainty.
      # Resolved from the NUCLEUS_REPO_ROOT env var that apply.sh exports before the
      # rebuild — avoids hard-coding a machine-specific absolute path.
      NUCLEUS_REPO_ROOT = builtins.getEnv "NUCLEUS_REPO_ROOT";
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
    # Method 3 (merge) — cannot use Method 1 (symlink) because QtPass manages
    # its own UI preferences via QSettings (macOS: defaults, Linux: INI,
    # Windows: registry). A symlink does not apply to these platform-native
    # stores. Merge writes the managed defaults into each store while
    # preserving any user-configured settings outside managed keys.
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
    home.activation.configurePicardSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            _upsert_ini_key() {
              _conf="$1"
              _section="$2"
              _key="$3"
              _value="$4"

              _conf_dir="$(dirname "$_conf")"
              mkdir -p "$_conf_dir"

              if [ -f "$_conf" ]; then
                _tmp="$(mktemp "$_conf.XXXXXX")"
                # Pass value through ENVIRON instead of -v to prevent AWK from
                # interpreting escape sequences (e.g. \0, \b, \x41) that appear
                # literally in Picard's @Variant(…) serialized Qt values.
                # AWK -v treats the argument as a string constant and processes
                # backslash escapes; ENVIRON reads the raw bytes unchanged.
                _UPSERT_VALUE="$_value" ${pkgs.gawk}/bin/awk -v section="$_section" -v key="$_key" '
                  function write_pair() {
                    if (wrote == 0) {
                      print key "=" value
                      wrote = 1
                    }
                  }
                  BEGIN {
                    in_target = 0
                    section_seen = 0
                    value = ENVIRON["_UPSERT_VALUE"]
                    wrote = 0
                  }
                  {
                    if ($0 ~ /^\[/) {
                      if (in_target) {
                        write_pair()
                        in_target = 0
                      }
                      if ($0 == "[" section "]") {
                        section_seen = 1
                        in_target = 1
                      }
                      print
                      next
                    }

                    if (in_target && $0 ~ ("^" key "=")) {
                      if (wrote == 0) {
                        print key "=" value
                        wrote = 1
                      }
                      next
                    }

                    print
                  }
                  END {
                    if (section_seen == 0) {
                      print "[" section "]"
                    }
                    if (wrote == 0) {
                      print key "=" value
                    }
                  }
                ' "$_conf" > "$_tmp"
                mv "$_tmp" "$_conf"
              else
                cat > "$_conf" <<EOF
      [$_section]
      $_key=$_value
      EOF
              fi
            }

            _apply_picard_defaults_from_file() {
              _defaults="$1"
              _conf="$2"

              ${pkgs.gawk}/bin/awk '
                BEGIN { section = "" }

                /^[[:space:]]*([;#]|$)/ { next }

                /^\[[^]]+\][[:space:]]*$/ {
                  section = $0
                  sub(/^\[/, "", section)
                  sub(/\][[:space:]]*$/, "", section)
                  next
                }

                {
                  if (section == "") {
                    next
                  }

                  pos = index($0, "=")
                  if (pos == 0) {
                    next
                  }

                  key = substr($0, 1, pos - 1)
                  value = substr($0, pos + 1)
                  gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

                  if (key != "") {
                    print section "\t" key "\t" value
                  }
                }
              ' "$_defaults" | while IFS=$'\t' read -r _section _key _value; do
                _upsert_ini_key "$_conf" "$_section" "$_key" "$_value"
              done
            }

            _picard_conf="''${XDG_CONFIG_HOME:-$HOME/.config}/MusicBrainz/Picard.ini"
            _picard_defaults_file="$(mktemp "''${TMPDIR:-/tmp}/picard-defaults.XXXXXX.ini")"
            trap 'rm -f "$_picard_defaults_file"' EXIT
            printf '%s' ${lib.escapeShellArg picardDefaultsIniText} > "$_picard_defaults_file"

            _apply_picard_defaults_from_file "$_picard_defaults_file" "$_picard_conf"
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

    # Protect out-of-store symlinks (mkOutOfStoreSymlink) against accidental
    # deletion between rebuilds.
    home.activation.unprotectOutOfStoreSymlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      ${builtins.readFile ../scripts/agent-helpers.sh}
      _nucleus_unprotect_symlink "home.nix" "$HOME/iCloud"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/camilladsp/configs"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/camillagui-backend/config.yml"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/discord-music-rpc/config.yaml"
      _nucleus_unprotect_symlink "home.nix" "$HOME/.config/starship.toml"
      _nucleus_unprotect_symlink "home.nix" "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
    '';

    home.activation.protectOutOfStoreSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      ${builtins.readFile ../scripts/agent-helpers.sh}
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
