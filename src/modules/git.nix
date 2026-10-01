# Shared Git behavior; identity is sourced from managed secrets.
{
  config,
  hostName,
  lib,
  managedUsername ? null,
  pkgs,
  repoRoot,
  username,
  ...
}:
let
  # Mirror home.nix's effective-user resolution: prefer the managed user's own
  # overlay directory, falling back to the shared defaults below.
  effectiveUsername = if managedUsername != null then managedUsername else username;

  overlay = (import ./lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot hostName;
  };

  selectUserGitFile = ext: overlay.selectSource "git" ext;

  # Activation helper bundle (seed-writable-symlink.sh) resolved at eval time;
  # the helper itself resolves the LIVE repo root at activation time.
  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  # User-scope gitconfig (~/.gitconfig), method-1 (writable) symlink to the
  # selected repo file against the LIVE repo root. HM's backupFileExtension
  # renames a pre-existing regular file to ~/.gitconfig.bak on first activation.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-git-gitconfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.gitconfig" \
      "${overlay.toRepoRelPath (selectUserGitFile "gitconfig")}" \
      "${hostName}"
  '';

  # User-scope ignore file (~/.config/git/ignore), method-1 (writable) symlink;
  # core.excludesFile in the user gitconfig points here. Git has no globally
  # scoped ignore file, so ignore content lives at user scope.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-git-gitignore = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/git/ignore" \
      "${overlay.toRepoRelPath (selectUserGitFile "gitignore")}" \
      "${hostName}"
  '';

  home.activation.assemble-git-empty-template = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # An empty init.templateDir suppresses the 15+ sample hooks and description
    # file Git would otherwise copy into every new .git directory.
    mkdir -p "$HOME/.config/git/empty_template"
  '';
}
