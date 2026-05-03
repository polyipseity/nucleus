# macbook/security.nix — Authentication and privilege-escalation hardening.
{ ... }:
{
  # Allow Touch ID to satisfy sudo authentication prompts via PAM.
  security.pam.services.sudo_local.touchIdAuth = true;

  # Write a sudoers drop-in that shortens the credential cache to 5 minutes,
  # reducing the window in which an unlocked terminal can escalate privilege.
  system.activationScripts.configureSudoTimeout.text = ''
    echo "Defaults timestamp_timeout=5" > /etc/sudoers.d/10-timeout
    chmod 440 /etc/sudoers.d/10-timeout
  '';
}
