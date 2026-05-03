# macbook/base.nix — Fundamental nix-darwin settings for the MacBook host.
{ pkgs, username, ... }:
{
  # Enable the Nix flakes and new nix CLI; required by this flake.
  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  # Zsh must be enabled system-wide so the nix-darwin PAM stack recognises it.
  programs.zsh.enable = true;

  # nix-darwin v5+ requires an explicit primary user for single-user tooling.
  system.primaryUser = username;
  system.stateVersion = 4;

  # Set zsh as the login shell for the managed user account.
  users.users.${username}.shell = pkgs.zsh;
}
