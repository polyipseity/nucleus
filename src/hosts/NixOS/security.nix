# NixOS/security.nix - privilege-escalation hardening.
{ lib, ... }: {
  programs.ssh.startAgent = true;
  # WHY: desktop.nix enables GNOME, whose gcr-ssh-agent (default-on via
  # gnome-keyring) asserts against the standalone programs.ssh agent above.
  # Keep the standalone agent and drop gcr's duplicate to satisfy the assertion.
  # Precedent: src/vms/NixOS/base-guest.nix forces the same override for guests.
  services.gnome.gcr-ssh-agent.enable = lib.mkForce false;

  # SSH for remote access, public keys only.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      # Keyboard-interactive stays off because PAM modules can still prompt for a
      # password through that channel even with PasswordAuthentication = false.
      # Source: https://mynixos.com/nixpkgs/option/services.openssh.settings.KbdInteractiveAuthentication
      KbdInteractiveAuthentication = false;
      # No direct password authentication: key pairs only.
      # Source: https://mynixos.com/nixpkgs/option/services.openssh.settings.PasswordAuthentication
      PasswordAuthentication = false;
      # The SOPS-materialized personal public key, never a hardcoded one.
      # secrets.nix writes ssh_personal_<username>.pub after decryption. %u
      # expands to the connecting username. .ssh/authorized_keys stays as the
      # conventional path for adding further keys later.
      # Source: https://man7.org/linux/man-pages/man5/sshd_config.5.html
      AuthorizedKeysFile = ".ssh/authorized_keys .ssh/ssh_personal_%u.pub";
    };
  };
}
