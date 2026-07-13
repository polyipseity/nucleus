# Starship cross-shell prompt — shared config for all POSIX hosts.
# Method 1 (writable symlink): repo changes take effect without reactivation
# since starship reads ~/.config/starship.toml at shell start.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  home.packages = [ pkgs.starship ];

  home.file.".config/starship.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/starship.toml";

  # Cache directory for Starship's computed state.
  # Scope: all-process — also set in gui-env LaunchAgent (macOS),
  # environment.variables (NixOS), and env.dsc.yml (Windows).
  home.sessionVariables = {
    STARSHIP_CACHE = "$HOME/.cache/starship";
    # STARSHIP_CONFIG is unset here — starship defaults to ~/.config/starship.toml
    # which the out-of-store symlink places it at. Windows sets this
    # explicitly via user/env.dsc.yml because mkOutOfStoreSymlink doesn't apply there.
  };
}
