# modules/git.nix — Shared Git behavior; identity is sourced from managed secrets.
{ lib, pkgs, ... }:
let
  gitIgnoreGlobalText = ''
    # https://github.com/github/gitignore/blob/1046d8fba6b42d367da6314c934cddb6bfe5662e/Nix.gitignore {
    # Ignore build outputs from performing a nix-build or `nix build` command
    result
    result-*

    # Ignore automatically generated direnv output
    .direnv

    # Ignore NixOS interactive test driver history
    **/.nixos-test-history
    # }
  '';
in
{
  # Keep a managed global ignore baseline plus a user-writable overlay file.
  # The activation step below assembles both into ~/.config/git/ignore so
  # users can add machine-local patterns without editing declarative files.
  xdg.configFile."git/ignore-global".text = gitIgnoreGlobalText;

  home.activation.gitIgnoreAssemble = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        set -eu

        _git_ignore_global="$HOME/.config/git/ignore-global"
        _git_ignore_user="$HOME/.config/git/ignore-user"
        _git_ignore_effective="$HOME/.config/git/ignore"

        if [ ! -f "$_git_ignore_user" ]; then
          cat > "$_git_ignore_user" <<'EOF'
    # User-specific Git ignore patterns.
    # Add one pattern per line; these are appended after ignore-global.
    EOF
        fi

        {
          cat "$_git_ignore_global"
          printf '\n'
          cat "$_git_ignore_user"
        } > "$_git_ignore_effective"
  '';

  programs.git = {
    enable = true;
    package = pkgs.gitFull;
    # Keep OpenPGP signing format pinned; user name/email/signing key are set by
    # the secrets activation path so identity stays SOPS-driven across hosts.
    # Enforce signed commits and tags by default on POSIX hosts to match the
    # Windows Sync-GitAndSshConfig baseline and keep cross-host behavior aligned.
    signing = {
      format = "openpgp";
    };
    settings = {
      commit.gpgsign = true;
      core.excludesFile = "~/.config/git/ignore";
      init.defaultBranch = "main";
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
