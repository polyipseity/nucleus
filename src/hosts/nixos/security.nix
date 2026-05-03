# nixos/security.nix — Privilege-escalation hardening for the NixOS host.
{ ... }:
{
  # Shorten the sudo credential cache to 5 minutes to reduce the window in
  # which an unattended terminal can perform privileged operations.
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=5
  '';
}
