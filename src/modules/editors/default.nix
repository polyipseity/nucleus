{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
  };
}
