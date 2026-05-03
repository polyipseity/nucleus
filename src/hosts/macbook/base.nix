# macbook/base.nix — Fundamental nix-darwin settings for the MacBook host.
{ pkgs, username, ... }:
{
  # Enable the Nix flakes and new nix CLI; required by this flake.
  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  # Allow Nix to use Rosetta for x86_64-darwin binaries on Apple Silicon.
  # Written to nix.conf by nix-darwin, so it applies to all users.
  nix.extraOptions = ''
    extra-platforms = x86_64-darwin aarch64-darwin
  '';

  # Zsh must be enabled system-wide so the nix-darwin PAM stack recognises it.
  programs.zsh.enable = true;

  # nix-darwin v5+ requires an explicit primary user for single-user tooling.
  system.primaryUser = username;
  system.stateVersion = 4;

  # Set zsh as the login shell for the managed user account.
  users.users.${username}.shell = pkgs.zsh;
}
