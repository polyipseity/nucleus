# modules/posix-security.nix — Shared privilege-escalation hardening.
# Imported by both nix-darwin and NixOS hosts.
{ ... }:
{
  # Shorten sudo credential caching to reduce unattended escalation window.
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=5
  '';
}
