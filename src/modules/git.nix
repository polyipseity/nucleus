# Shared Git behavior; identity is sourced from managed secrets.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  activationBundle = pkgs.callPackage ./lib/activation-bundle.nix { };
in
{
  # Keep a managed global ignore baseline plus a user-writable overlay file.
  # The activation step below assembles both into ~/.config/git/ignore so
  # users can add machine-local patterns without editing declarative files.
  xdg.configFile."git/ignore-global" = {
    # Method 1 (writable symlink): repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/git/system.gitignore";
  };

  home.activation.gitIgnoreAssemble = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/bin/assemble-git-ignore"
  '';

  home.activation.gitEmptyTemplate = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # Ensure the empty template directory exists so `init.templateDir` always
    # points at an existing (but empty) directory.  This suppresses the 15+ sample
    # hook scripts and description file that Git otherwise copies into every new
    # .git directory from the system template store.
    mkdir -p "$HOME/.config/git/empty_template"
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
      # Disable line-ending conversion on all POSIX hosts; autocrlf is set to
      # true on Windows to normalise CRLF → LF on commit there.
      core.autocrlf = false;
      core.excludesFile = "~/.config/git/ignore";
      # Enable symlink support explicitly; matches the Windows baseline where
      # Developer Mode is required for unprivileged symlink creation.
      core.symlinks = true;
      # Prune deleted remote-tracking branches and tags on every fetch so stale
      # refs do not linger indefinitely across long-lived machines.
      fetch.prune = true;
      fetch.pruneTags = true;
      init.defaultBranch = "main";
      # Point init.templateDir at an empty directory we manage during activation
      # so `git init` and `git clone` never create hooks/*.sample or the legacy
      # description file.  The activation block below ensures the target dir exists.
      init.templateDir = "~/.config/git/empty_template";
      # Pull in name/email/signingkey written by the git-identity activation
      # hook at ~/.config/git/identity.  Using an include file lets the hook write
      # to a path it owns without touching the HM-managed (read-only) config symlink.
      # Pin the OpenPGP binary path so Git uses the same managed gnupg build as
      # the rest of the profile, avoiding silent version drift when PATH and
      # an unrelated store path diverge across rebuilds.
      gpg."openpgp".program = "${pkgs.gnupg}/bin/gpg";
      include.path = "~/.config/git/identity";
      # `push.autoSetupRemote` makes `git push` on a branch without an upstream
      # automatically configure the upstream to the same-named remote branch,
      # avoiding the need for `--set-upstream`/`-u`.
      push.autoSetupRemote = true;
      # `push.followTags` is Git's built-in "push the tags that belong with the
      # commits I just pushed" toggle; it avoids a custom alias while keeping
      # release/signing tags in sync with ordinary branch pushes.
      push.followTags = true;
      tag.gpgsign = true;
      # Rewrite GitHub HTTPS remotes to SSH globally for this user so clones and
      # future remotes authenticate with the managed SSH identity automatically.
      url."git@github.com:".insteadOf = "https://github.com/";
      user.useConfigOnly = true;
    };
  };
}
