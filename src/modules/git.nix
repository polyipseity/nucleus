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

  overlay = (import ./lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot hostName;
  };

  selectUserGitFile = ext: overlay.selectSource "git" ext;

  # Activation helper bundle (seed-writable-symlink.sh) resolved at eval time;
  # the helper itself resolves the LIVE repo root at activation time.
  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  # User-scope gitconfig (~/.gitconfig) as a method-1 (writable) symlink to the
  # selected repo file, created at activation time against the LIVE repo root so
  # repo changes take effect without rebuild. HM's backupFileExtension renames a
  # pre-existing regular file to ~/.gitconfig.bak (same folder) on first activation.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-git-gitconfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.gitconfig" \
      "${overlay.toRepoRelPath (selectUserGitFile "gitconfig")}" \
      "${hostName}"
  '';

  # User-scope ignore file (~/.config/git/ignore) as a method-1 (writable) symlink
  # to the selected repo file; core.excludesFile in the user gitconfig points here.
  # Git has no global-scoped ignore file, so ignore content lives at user scope.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-git-gitignore = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/git/ignore" \
      "${overlay.toRepoRelPath (selectUserGitFile "gitignore")}" \
      "${hostName}"
  '';

  home.activation.assemble-git-empty-template = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # Ensure the empty template directory exists so `init.templateDir` always
    # points at an existing (but empty) directory.  This suppresses the 15+ sample
    # hook scripts and description file that Git otherwise copies into every new
    # .git directory from the system template store.
    mkdir -p "$HOME/.config/git/empty_template"
  '';
}
