# modules/home.nix — Home Manager entrypoint shared by all three host types.
#
# Imported by flake.nix once per host inside a home-manager.users.* block or a
# homeManagerConfiguration call.  Responsible for:
#   • resolving the platform-appropriate home directory path
#   • importing all shared feature modules
#   • symlinking dotfiles from the repo's dotfiles/ tree into the home directory
{ lib, pkgs, username ? "user", homeDirectory ? null, ... }:
let
  # Derive the home directory from the passed-in argument when provided,
  # otherwise fall back to the platform convention.
  resolvedHomeDirectory =
    if homeDirectory != null then homeDirectory
    else if pkgs.stdenv.isDarwin then "/Users/${username}"
    else "/home/${username}";

  # Path to the checked-out dotfiles/ directory at the root of this repo.
  dotfilesRoot = ../dotfiles;
in
{
  imports = [
    ./core.nix
    ./editors.nix
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
  ];
}
