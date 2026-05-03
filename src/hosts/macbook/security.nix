# macbook/security.nix — Authentication and privilege-escalation hardening.
{ ... }:
{
  # Allow Touch ID to satisfy sudo authentication prompts via PAM.
  security.pam.services.sudo_local.touchIdAuth = true;

  # Shorten the credential cache to 5 minutes, reducing the window in which
  # an unlocked terminal can escalate privilege.  Mirrors the same option used
  # in src/hosts/nixos/security.nix.
  security.sudo.extraConfig = "Defaults timestamp_timeout=5";
}
