# modules/editors.nix — Editor installations shared across all managed hosts.
# Neovim is configured as the system-wide default editor (EDITOR / VISUAL env
# vars) so CLI tools such as git and crontab launch it automatically.
{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true; # sets $EDITOR and $VISUAL to nvim
    # Pin explicit values to avoid version-gated default warnings and to adopt
    # the new Home Manager defaults intentionally.
    withPython3 = false;
    withRuby = false;
  };

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
  };
}
