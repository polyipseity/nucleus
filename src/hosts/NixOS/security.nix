# NixOS/security.nix — Privilege-escalation hardening for the NixOS host.
{ lib, ... }: {
  # Enable the user-level SSH agent via programs.ssh. macOS and Windows
  # already have ssh-agent managed through their native service mechanisms.
  programs.ssh.startAgent = true;
  # WHY: desktop.nix enables GNOME, whose gcr-ssh-agent (default-on via
  # gnome-keyring) asserts against the standalone programs.ssh agent above.
  # Keep the standalone agent and drop gcr's duplicate to satisfy the assertion.
  # Precedent: src/vms/NixOS/base-guest.nix forces the same override for guests.
  services.gnome.gcr-ssh-agent.enable = lib.mkForce false;
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
      # Source: NixOS OpenSSH option for keyboard-interactive auth.
      # https://mynixos.com/nixpkgs/option/services.openssh.settings.KbdInteractiveAuthentication
      KbdInteractiveAuthentication = false;
      # Disable direct password authentication, forcing all logins to use
      # a public/private key pair.  Eliminates brute-force password attacks
      # over SSH entirely.
      # Source: NixOS OpenSSH option for password auth.
      # https://mynixos.com/nixpkgs/option/services.openssh.settings.PasswordAuthentication
      PasswordAuthentication = false;
      # Reference the SOPS-materialized personal SSH public key so the
      # authorized key is never hardcoded in the repository.  secrets.nix
      # materializes ssh_personal_<username>.pub to
      # ~/.ssh/ssh_personal_<username>.pub after SOPS decryption.
      # %u expands to the connecting username at authentication time.
      # .ssh/authorized_keys is retained as the conventional extensibility path
      # for adding further authorized keys declaratively or manually later.
      # Source: sshd_config AuthorizedKeysFile semantics.
      # https://man7.org/linux/man-pages/man5/sshd_config.5.html
      AuthorizedKeysFile = ".ssh/authorized_keys .ssh/ssh_personal_%u.pub";
    };
  };
}
