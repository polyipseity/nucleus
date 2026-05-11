# modules/home.nix — Home Manager entrypoint shared by all three host types.
#
# Imported by flake.nix once per host inside a home-manager.users.* block or a
# homeManagerConfiguration call.  Responsible for:
#   • resolving the platform-appropriate home directory path
#   • importing all shared feature modules
#   • symlinking dotfiles from the repo's dotfiles/ tree into the home directory
{ config, lib, pkgs, username, users ? null, managedUsername ? null, managedUser ? null, hostManualFile ? null, ... }:
let
  # Determine the effective user context for this Home Manager evaluation.
  # managedUsername/managedUser are injected by mkHomeManagerUsers for
  # multi-user host evaluations; fallback to legacy args for standalone usage.
  effectiveUsername =
    if managedUsername != null then managedUsername
    else username;

  effectiveUser =
    if managedUser != null then managedUser
    else if users != null && builtins.hasAttr effectiveUsername users then users.${effectiveUsername}
    else { };

  # Derive the home directory from platform conventions. Keeping this local to
  # the module avoids relying on ad-hoc `_module.args` plumbed through every
  # call site.
  resolvedHomeDirectory =
    if effectiveUser ? homeDirectory then effectiveUser.homeDirectory
    else if pkgs.stdenv.isDarwin then "/Users/${effectiveUsername}"
    else "/home/${effectiveUsername}";

  passwordStoreDir =
    if effectiveUser ? passwordStore && effectiveUser.passwordStore ? path then
      builtins.replaceStrings [ "~" ] [ resolvedHomeDirectory ] effectiveUser.passwordStore.path
    else "${resolvedHomeDirectory}/.password-store";

  # Path to the checked-out dotfiles/ directory at the root of this repo.
  dotfilesRoot = ../dotfiles;
in
{
  options.nucleus.hostManualFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Host-scoped MANUAL.md path (absolute or repo-relative) printed by OS-specific activation modules at the end of Home Manager activation.";
  };

  imports = [
    ./agents.nix
    ./ai
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

    # QtPass keeps its own persisted `passStore` setting, which can override
    # PASSWORD_STORE_DIR when launched from GUI surfaces.
    #
    # - macOS: configure the com.ijhack.QtPass defaults domain.
    # - Linux: configure Qt's INI-backed settings file (QSettings).
    #
    # Keep both aligned with the per-user passwordStoreDir.
    home.activation.configureQtPassStore = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      _qtpass_store=${lib.escapeShellArg passwordStoreDir}
      case "$_qtpass_store" in
        */) ;;
        *) _qtpass_store="$_qtpass_store/" ;;
      esac

      _update_qtpass_ini() {
        _conf="$1"
        _conf_dir="$(dirname "$_conf")"
        mkdir -p "$_conf_dir"

        if [ -f "$_conf" ]; then
          _tmp="$(mktemp "$_conf.XXXXXX")"
          awk -v store="$_qtpass_store" '
            BEGIN { in_general = 0; wrote = 0 }
            {
              if ($0 ~ /^\[General\]$/) {
                if (in_general && wrote == 0) {
                  print "passStore=" store
                  wrote = 1
                }
                in_general = 1
                print
                next
              }

              if ($0 ~ /^\[/ && $0 !~ /^\[General\]$/) {
                if (in_general && wrote == 0) {
                  print "passStore=" store
                  wrote = 1
                }
                in_general = 0
                print
                next
              }

              if (in_general && $0 ~ /^passStore=/) {
                if (wrote == 0) {
                  print "passStore=" store
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
                print "passStore=" store
              }
            }
          ' "$_conf" > "$_tmp"
          mv "$_tmp" "$_conf"
        else
          cat > "$_conf" <<EOF
[General]
passStore=$_qtpass_store
EOF
        fi
      }

      case "$(uname -s)" in
        Darwin)
          /usr/bin/defaults write com.ijhack.QtPass passStore -string "$_qtpass_store"
          ;;
        Linux)
          # QtPass upstream commonly resolves to ~/.config/IJHack/QtPass.conf.
          _primary_conf="$HOME/.config/IJHack/QtPass.conf"
          # Some builds may resolve via organization-domain pathing.
          _secondary_conf="$HOME/.config/com.ijhack/QtPass.conf"

          _update_qtpass_ini "$_primary_conf"
          if [ -f "$_secondary_conf" ]; then
            _update_qtpass_ini "$_secondary_conf"
          fi
          ;;
      esac
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
        "iCloud".source = config.lib.file.mkOutOfStoreSymlink "${resolvedHomeDirectory}/Library/Mobile Documents/com~apple~CloudDocs";
      })
    ];
  };
}
