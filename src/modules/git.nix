# modules/git.nix — Shared Git behavior; identity is sourced from managed secrets.
{ ... }:
{
  programs.git = {
    enable = true;
    # Keep OpenPGP signing format pinned; user name/email/signing key are set by
    # the secrets activation path so identity stays SOPS-driven across hosts.
    # Enforce signed commits and tags by default on POSIX hosts to match the
    # Windows Sync-GitAndSshConfig baseline and keep cross-host behavior aligned.
    signing = {
      format = "openpgp";
    };
    settings = {
      commit.gpgsign = true;
      # Pull in name/email/signingkey written by the gitIdentityFromSops activation
      # hook at ~/.config/git/identity.  Using an include file lets the hook write
      # to a path it owns without touching the HM-managed (read-only) config symlink.
      include.path = "~/.config/git/identity";
      tag.gpgsign = true;
      # Rewrite GitHub HTTPS remotes to SSH globally for this user so clones and
      # future remotes authenticate with the managed SSH identity automatically.
      url."git@github.com:".insteadOf = "https://github.com/";
      user.useConfigOnly = true;
    };
  };
}
