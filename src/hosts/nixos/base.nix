# nixos/base.nix — Fundamental NixOS settings common to this host.
{ ... }:
{
  # Keep device firmware update support enabled (parity with the
  # "automatic critical updates" posture on macOS).
  services.fwupd.enable = true;

  # Changing stateVersion after initial installation requires a migration;
  # keep this pinned to the NixOS release used when this host was first built.
  system.stateVersion = "24.11";
}
