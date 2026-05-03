{ lib, pkgs, username ? "user", homeDirectory ? null, ... }:
let
  resolvedHomeDirectory =
    if homeDirectory != null then homeDirectory
    else if pkgs.stdenv.isDarwin then "/Users/${username}"
    else "/home/${username}";

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
    stateVersion = "24.11";
  };

  programs.home-manager.enable = true;

  home.file = lib.mkMerge [
    (lib.optionalAttrs (builtins.pathExists (dotfilesRoot + "/.config")) {
      ".config".source = dotfilesRoot + "/.config";
    })
    (lib.optionalAttrs (builtins.pathExists (dotfilesRoot + "/.gitconfig")) {
      ".gitconfig".source = dotfilesRoot + "/.gitconfig";
    })
  ];
}
