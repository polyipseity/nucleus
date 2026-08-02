# Shared Git behavior; identity is sourced from managed secrets.
{
  config,
  lib,
  hostName,
  username,
  managedUsername ? null,
  ...
}:
let
  # Mirror home.nix's effective-user resolution: prefer the managed user's own
  # overlay directory, falling back to the shared defaults below.
  effectiveUsername = if managedUsername != null then managedUsername else username;

  # Defaults-fallback selection (per-user dir wins, else default/git/), matching
  # the src/users/<username>/ → src/users/default/ convention in AGENTS.md.
  selectUserGitFile =
    ext:
    let
      perUser = "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/users/${effectiveUsername}/git/${hostName}.${ext}";
      default = "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/users/default/git/${hostName}.${ext}";
    in
    if builtins.pathExists perUser then perUser else default;
in
{
  # User-scope gitconfig (~/.gitconfig) as a writable symlink to the selected
  # repo file.  HM's backupFileExtension renames a pre-existing regular file to
  # ~/.gitconfig.bak (same folder) on first activation.
  home.file."\.gitconfig" = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink (selectUserGitFile "gitconfig");
  };

  # User-scope ignore file (~/.config/git/ignore) as a writable symlink to the
  # selected repo file; core.excludesFile in the user gitconfig points here.
  # Git has no global-scoped ignore file, so ignore content lives at user scope.
  xdg.configFile."git/ignore" = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink (selectUserGitFile "gitignore");
  };

  home.activation.assemble-git-empty-template = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # Ensure the empty template directory exists so `init.templateDir` always
    # points at an existing (but empty) directory.  This suppresses the 15+ sample
    # hook scripts and description file that Git otherwise copies into every new
    # .git directory from the system template store.
    mkdir -p "$HOME/.config/git/empty_template"
  '';
}
