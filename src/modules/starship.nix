# Starship cross-shell prompt — shared config for all POSIX hosts.
{ lib, pkgs, ... }: {
  home.packages = [ pkgs.starship ];

  xdg.configFile."starship.toml".source = ./configs/starship.toml;

  # Cache directory for Starship's computed state.
  home.sessionVariables = {
    STARSHIP_CACHE = "$HOME/.cache/starship";
    # STARSHIP_CONFIG is unset here — starship defaults to ~/.config/starship.toml
    # which xdg.configFile places the managed config at. Windows sets this
    # explicitly via user/env.dsc.yml because xdg.configFile doesn't apply there.
  };
}
