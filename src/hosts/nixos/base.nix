{ ... }:
{
  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  programs.zsh.enable = true;

  system.stateVersion = "24.11";
}
