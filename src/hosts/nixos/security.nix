# nixos/security.nix — Privilege-escalation hardening for the NixOS host.
{ ... }:
{
  # Keep SSH remote access available while using key-based auth only.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
    };
  };
}
