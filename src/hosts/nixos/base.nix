# nixos/base.nix — Fundamental NixOS settings common to this host.
{ ... }:
{
  # Changing stateVersion after initial installation requires a migration;
  # keep this pinned to the NixOS release used when this host was first built.
  system.stateVersion = "24.11";
}
