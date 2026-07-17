# Starship cross-shell prompt — shared config for all hosts.
# Method 1 (writable symlink): repo changes take effect without reactivation
# since starship reads ~/.config/starship.toml at shell start.
# Windows: deployed via Deploy-WritableSymlink in ConfigHelpers.ps1 (same method).
{
  lib,
  pkgs,
  config,
  ...
}:
{
  home.packages = [ pkgs.starship ];

  home.file.".config/starship.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/starship/starship.toml";

  # STARSHIP_CACHE and STARSHIP_CONFIG are defined in the centralized env var
  # catalog (src/modules/lib/env-catalog.nix) and injected via shell.nix's
  # home.sessionVariables.  No separate declaration needed.
}
