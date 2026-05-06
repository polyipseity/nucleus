# nixos/security.nix — Privilege-escalation hardening for the NixOS host.
{ ... }:
{
  # Enable SSH for remote access while restricting authentication to public
  # keys only.  Both password mechanisms are disabled so the attack surface is
  # limited to key material, which cannot be brute-forced over the network.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      # Disable keyboard-interactive authentication (covers PAM password
      # prompts and challenge-response exchanges).  Without this, even with
      # PasswordAuthentication = false, some PAM modules could still prompt
      # for a password via the keyboard-interactive channel.
      KbdInteractiveAuthentication = false;
      # Disable direct password authentication, forcing all logins to use
      # a public/private key pair.  Eliminates brute-force password attacks
      # over SSH entirely.
      PasswordAuthentication = false;
      # Reference the SOPS-materialized personal SSH public key so the
      # authorized key is never hardcoded in the repository.  secrets.nix
      # materializes ssh_personal_<username>.pub to
      # ~/.ssh/ssh_personal_<username>.pub after SOPS decryption.
      # %u expands to the connecting username at authentication time.
      # .ssh/authorized_keys is retained as the conventional extensibility path
      # for adding further authorized keys declaratively or manually later.
      AuthorizedKeysFile = ".ssh/authorized_keys .ssh/ssh_personal_%u.pub";
    };
  };
}
