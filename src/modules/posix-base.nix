# modules/posix-base.nix — Shared system-layer defaults for POSIX hosts.
# Imported by both nix-darwin and NixOS host entrypoints.
{ ... }:
{
  # Enable the Nix flakes and new nix CLI consistently on both hosts.
  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  # Ensure zsh is available as a valid login shell system-wide.
  programs.zsh.enable = true;
}
