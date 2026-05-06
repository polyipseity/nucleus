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

  # Enable Remote Login (OpenSSH server) so this Mac is reachable over SSH
  # for administration and tunneling.
  services.ssh.enable = true;

  # Enforce key-only authentication for the SSH server and configure the
  # AuthorizedKeysFile to read from the SOPS-materialized personal public key
  # so the key is never hardcoded in the repository.
  # %u expands to the connecting username; secrets.nix materializes
  # ssh_personal_<username>.pub to ~/.ssh/ssh_personal_<username>.pub.
  # Both the standard authorized_keys path and the materialized personal key
  # are checked to allow future key additions via authorized_keys.
  environment.etc."ssh/sshd_config.d/50-nucleus.conf".text = ''
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ChallengeResponseAuthentication no
    AuthorizedKeysFile .ssh/authorized_keys .ssh/ssh_personal_%u.pub
  '';
}
