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
      homeDirectory = resolvedHomeDirectory;
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

    # QtPass keeps its own persisted `passStore` setting. On macOS that value
    # is stored in the com.ijhack.QtPass defaults domain and can override the
    # shell-exported PASSWORD_STORE_DIR when QtPass is launched from GUI
    # surfaces. Keep it aligned with the per-user passwordStoreDir.
    home.activation.configureQtPassStore = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ "$(uname -s)" = "Darwin" ]; then
        _qtpass_store=${lib.escapeShellArg passwordStoreDir}
        case "$_qtpass_store" in
          */) ;;
          *) _qtpass_store="$_qtpass_store/" ;;
        esac

        /usr/bin/defaults write com.ijhack.QtPass passStore -string "$_qtpass_store"
      fi
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
