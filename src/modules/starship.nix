# Starship cross-shell prompt — shared config for all hosts.
{
  config,
  pkgs,
  managedUsername ? null,
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

  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  overlay = (import ./lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  starshipConfigFile = overlay.selectFile "starship" "starship.toml";
in
{
  home.packages = [ pkgs.starship ];

  home.file.".config/starship.toml".source =
    config.lib.file.mkOutOfStoreSymlink
      # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without reactivation since starship reads ~/.config/starship.toml at shell start. Windows: deployed via Deploy-WritableSymlink in ConfigHelpers.ps1 (same method).
      starshipConfigFile;

  # STARSHIP_CACHE and STARSHIP_CONFIG are defined in the centralized env var
  # catalog (src/modules/lib/env-catalog.nix) and injected via shell.nix's
  # home.sessionVariables.  No separate declaration needed.
}
