{ ... }:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      ll = "eza -la";
      gs = "git status -sb";
    };
  };

  programs.fish = {
    enable = true;
    shellAliases = {
      ll = "eza -la";
      gs = "git status -sb";
    };
  };

  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
    enableFishIntegration = true;
  };
}
