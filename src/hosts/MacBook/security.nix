# MacBook/security.nix - authentication and privilege-escalation hardening.
{ ... }: {
  # Touch ID satisfies sudo prompts through PAM under the `sudo_local` service,
  # not `sudo`: SIP protects /etc/pam.d/sudo so nix-darwin cannot write it,
  # while /etc/pam.d/sudo_local is included by sudo and outside SIP. macOS
  # updates also overwrite /etc/pam.d/sudo, which would drop direct edits.
  security.pam.services.sudo_local.touchIdAuth = true;

  # Remote Login (OpenSSH server) for administration and tunneling. In this
  # nix-darwin version the option path is services.openssh, not services.ssh.
  services.openssh.enable = true;

  # Key-only SSH auth reading the SOPS-materialized personal public key, so no key
  # is hardcoded in the repo. secrets.nix writes ssh_personal_<username>.pub and
  # %u expands to the connecting username. authorized_keys stays checked so more
  # keys can be added later.
  # check-suppress:config-method: method 2 (read-only) -- Security-sensitive SSH server config -- changes go through Nix evaluation and are traceable in git.
  environment.etc."ssh/sshd_config.d/50-nucleus.conf".text =
    builtins.readFile ../../modules/configs/ssh/sshd_config.d/50-nucleus.conf;
}
