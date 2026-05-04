# modules/home.nix — Home Manager entrypoint shared by all three host types.
#
# Imported by flake.nix once per host inside a home-manager.users.* block or a
# homeManagerConfiguration call.  Responsible for:
#   • resolving the platform-appropriate home directory path
#   • importing all shared feature modules
#   • symlinking dotfiles from the repo's dotfiles/ tree into the home directory
{ config, lib, pkgs, username, ... }:
let
  # Derive the home directory from platform conventions. Keeping this local to
  # the module avoids relying on ad-hoc `_module.args` plumbed through every
  # call site.
  resolvedHomeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/${username}"
    else "/home/${username}";

  # Path to the checked-out dotfiles/ directory at the root of this repo.
  dotfilesRoot = ../dotfiles;
in
{
  imports = [
    ./core.nix
    ./editors.nix
    ./linux.nix
    ./macos.nix
    ./secrets.nix
    ./shell.nix
    ./wallpapers.nix
  ];

  home = {
    inherit username;
    homeDirectory = resolvedHomeDirectory;
    # Pin the Home Manager state version; changing this after initial
    # activation requires a deliberate migration.
    stateVersion = "24.11";
  };

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
}
