# macbook/security.nix — Authentication and privilege-escalation hardening.
{ ... }:
{
  # Allow Touch ID to satisfy sudo authentication prompts via PAM.
  #
  # The service name is `sudo_local`, not `sudo`, for two reasons:
  #   1. macOS SIP protects /etc/pam.d/sudo from modification, so nix-darwin
  #      cannot write Touch ID support there.
  #   2. /etc/pam.d/sudo_local is explicitly included by /etc/pam.d/sudo and
  #      is NOT covered by SIP, so nix-darwin can write it safely.
  # Using sudo_local also makes the setting survive macOS updates, which
  # periodically overwrite /etc/pam.d/sudo and would remove any direct edits.
  security.pam.services.sudo_local.touchIdAuth = true;
}
