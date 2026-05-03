# modules/editors.nix — Editor installations shared across all managed hosts.
# Neovim is configured as the system-wide default editor (EDITOR / VISUAL env
# vars) so CLI tools such as git and crontab launch it automatically.
{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true; # sets $EDITOR and $VISUAL to nvim
  };

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
  };
}
