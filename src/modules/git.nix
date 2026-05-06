# modules/git.nix — Shared Git behavior; identity is sourced from managed secrets.
{ ... }:
{
  programs.git = {
    enable = true;
    # Keep OpenPGP signing format pinned; user name/email/signing key are set by
    # the secrets activation path so identity stays SOPS-driven across hosts.
    signing = {
      format = "openpgp";
    };
    settings = {
      # Rewrite GitHub HTTPS remotes to SSH globally for this user so clones and
      # future remotes authenticate with the managed SSH identity automatically.
      url."git@github.com:".insteadOf = "https://github.com/";
      user.useConfigOnly = true;
    };
  };
}
