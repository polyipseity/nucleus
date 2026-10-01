# Starship cross-shell prompt: shared config for all hosts.
{
  config,
  lib,
  managedUsername ? null,
  pkgs,
  repoRoot,
  username ? null,
  ...
}:
let
  effectiveUsername =
    if managedUsername != null then
      managedUsername
    else if username != null then
      username
    else
      config.home.username;

  overlay = (import ../lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  starshipConfigFile = overlay.selectFile "starship" "starship.toml";

  # Activation helper bundle (seed-writable-symlink.sh) resolved at eval time;
  # the helper itself resolves the LIVE repo root at activation time.
  activationBundle = pkgs.callPackage ../lib/script-tree.nix { };
in
{
  # ~/.config/starship.toml, method-1 (writable) symlink to the selected repo file
  # against the LIVE repo root, so repo changes apply at the next shell start
  # without reactivation. Windows uses Deploy-WritableSymlink, same method.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-starship-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/starship.toml" \
      "${overlay.toRepoRelPath starshipConfigFile}"
  '';

  # STARSHIP_CACHE and STARSHIP_CONFIG come from the env var catalog
  # (src/modules/lib/env-secrets.nix) via shell.nix's home.sessionVariables.
}
