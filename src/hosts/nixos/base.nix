# nixos/base.nix — Fundamental NixOS settings common to this host.
{ ... }:
{
  # Enable the Nix flakes and new nix CLI; required by this flake.
  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  # Zsh must be enabled system-wide so it is available as a login shell.
  programs.zsh.enable = true;

  # Changing stateVersion after initial installation requires a migration;
  # keep this pinned to the NixOS release used when this host was first built.
  system.stateVersion = "24.11";
}
