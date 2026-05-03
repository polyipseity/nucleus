# macbook/security.nix — Authentication and privilege-escalation hardening.
{ ... }:
{
  # Allow Touch ID to satisfy sudo authentication prompts via PAM.
  security.pam.services.sudo_local.touchIdAuth = true;
}
