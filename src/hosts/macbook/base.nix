{ pkgs, username, ... }:
{
  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  programs.zsh.enable = true;

  system.primaryUser = username;
  system.stateVersion = 4;

  users.users.${username}.shell = pkgs.zsh;
}
